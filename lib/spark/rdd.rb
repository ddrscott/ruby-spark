require "sourcify"

# Resilient Distributed Dataset

module Spark
  class RDD

    attr_reader :jrdd, :context, :command

    def initialize(jrdd, context, serializer)
      @jrdd = jrdd
      @context = context

      @cached = false
      @checkpointed = false

      @command = Spark::Command::Builder.new(serializer)
    end



    # =======================================================================    
    # Commad 
    # ======================================================================= 

    def attach(*args)
      @command.add_pre(args)
      self
    end

    def add_library(*args)
      @command.add_library(args)
      self
    end

    def attached
      @command.attached
    end

    # Make a copy of command for new PipelinedRDD
    # .dup and .clone does not do deep copy of @command.template
    def add_command(main, f=nil, options={})
      command = Marshal.load(Marshal.dump(@command))
      command.add(main, f, options)
      command
    end


    # =======================================================================    
    # Variables 
    # =======================================================================   

    def default_reduce_partitions
      if @context.conf.contains("spark.default.parallelism")
        @context.default_parallelism
      else
        @jrdd.partitions.size
      end
    end

    def id
      @jrdd.id
    end

    def cached?
      @cached
    end

    def checkpointed?
      @checkpointed
    end



    # =======================================================================
    # Computing functions
    # =======================================================================     

    #
    # Return an array that contains all of the elements in this RDD.
    #
    def collect
      # @serializer.load(jrdd.collect.iterator)
      @command.serializer.load(jrdd.collect.to_a)
    end

    #
    # Convert an Array to Hash
    #
    def collect_as_hash
      Hash[collect]
    end

    #
    # Return a new RDD by applying a function to all elements of this RDD.
    #
    # rdd = $sc.parallelize(0..5)
    # rdd.map(lambda {|x| x*2}).collect
    # => [0, 2, 4, 6, 8, 10]
    #
    def map(f, options={})
      main = "Proc.new {|iterator| iterator.map!{|i| @__main__.call(i)} }"
      comm = add_command(main, f, options)

      PipelinedRDD.new(self, comm)
    end

    #
    # Return a new RDD by first applying a function to all elements of this
    # RDD, and then flattening the results.
    #
    # rdd = $sc.parallelize(0..5)
    # rdd.flat_map(lambda {|x| [x, 1]}).collect
    # => [0, 1, 2, 1, 4, 1, 6, 1, 8, 1, 10, 1]
    #
    def flat_map(f, options={})
      main = "Proc.new {|iterator| iterator.map!{|i| @__main__.call(i)}.flatten! }"
      comm = add_command(main, f, options)

      PipelinedRDD.new(self, comm)
    end

    #
    # Return a new RDD by applying a function to each partition of this RDD.
    #
    # rdd = $sc.parallelize(0..10, 2)
    # rdd.map_partitions(lambda{|part| part.reduce(:+)}).collect
    # => [15, 40]
    #
    def map_partitions(f, options={})
      main = "Proc.new {|iterator| @__main__.call(iterator) }"
      comm = add_command(main, f, options)

      PipelinedRDD.new(self, comm)
    end

    #
    # Return a new RDD by applying a function to each partition of this RDD, while tracking the index
    # of the original partition.
    #
    # rdd = $sc.parallelize(0...4, 4)
    # rdd.map_partitions_with_index(lambda{|part, index| part[0] * index}).collect
    # => [0, 1, 4, 9]
    #
    def map_partitions_with_index(f, options={})
      main = "Proc.new {|iterator, index| @__main__.call(iterator, index) }"
      comm = add_command(main, f, options)

      PipelinedRDD.new(self, comm)
    end

    #
    # Return a new RDD containing only the elements that satisfy a predicate.
    #
    # rdd = $sc.parallelize(0..10)
    # rdd.filter(lambda{|x| x.even?}).collect
    # => [0, 2, 4, 6, 8, 10]
    #
    def filter(f, options={})
      main = "Proc.new {|iterator| iterator.select{|i| @__main__.call(i)} }"
      comm = add_command(main, f, options)

      PipelinedRDD.new(self, comm)
    end

    #
    # Return an RDD created by coalescing all elements within each partition into an array.
    #
    # rdd = $sc.parallelize(0..10, 3)
    # rdd.glom.collect
    # => [[0, 1, 2], [3, 4, 5, 6], [7, 8, 9, 10]]
    #
    def glom
      main = "Proc.new {|iterator| [iterator] }"
      comm = add_command(main)

      PipelinedRDD.new(self, comm)
    end

    #
    # Return a new RDD that is reduced into `numPartitions` partitions.
    #
    # rdd = $sc.parallelize(0..10, 3)
    # rdd.coalesce(2).glom.collect
    # => [[0, 1, 2], [3, 4, 5, 6, 7, 8, 9, 10]]
    #
    def coalesce(num_partitions)
      new_jrdd = jrdd.coalesce(num_partitions)
      RDD.new(new_jrdd, context, @command.serializer)
    end

    #
    # Merge the values for each key using an associative reduce function. This will also perform
    # the merging locally on each mapper before sending results to a reducer, similarly to a
    # "combiner" in MapReduce. Output will be hash-partitioned with the existing partitioner/
    # parallelism level.
    #
    # rdd = $sc.parallelize(["a","b","c","a","b","c","a","c"]).map(lambda{|x| [x, 1]})
    # rdd.reduce_by_key(lambda{|x,y| x+y}).collect_as_hash
    #
    # => {"a"=>3, "b"=>2, "c"=>3}
    #
    def reduce_by_key(f, num_partitions=nil)
      combine_by_key("lambda {|x| x}", f, f, num_partitions)
    end

    #
    # Generic function to combine the elements for each key using a custom set of aggregation
    # functions. Turns a JavaPairRDD[(K, V)] into a result of type JavaPairRDD[(K, C)], for a
    # "combined type" C * Note that V and C can be different -- for example, one might group an
    # RDD of type (Int, Int) into an RDD of type (Int, List[Int]). Users provide three
    # functions:
    #
    #   createCombiner: which turns a V into a C (e.g., creates a one-element list)
    #   mergeValue: to merge a V into a C (e.g., adds it to the end of a list)
    #   mergeCombiners: to combine two C's into a single one.
    #
    # def combiner(x)
    #   x
    # end
    # def merge(x,y)
    #   x+y
    # end
    # rdd = $sc.parallelize(["a","b","c","a","b","c","a","c"]).map(lambda{|x| [x, 1]})
    # rdd.combine_by_key(:combiner, :merge, :merge).collect_as_hash
    #
    # => {"a"=>3, "b"=>2, "c"=>3}
    #
    def combine_by_key(create_combiner, merge_value, merge_combiners, num_partitions=nil)
      num_partitions ||= default_reduce_partitions

      _combine_ = <<-COMBINE
        Proc.new{|iterator|
          combiners = {}
          iterator.each do |key, value|
            if combiners.has_key?(key)
              combiners[key] = @__merge_value__.call(combiners[key], value)
            else
              combiners[key] = @__create_combiner__.call(value)
            end
          end
          combiners.to_a
        }
      COMBINE

      _merge_ = <<-MERGE
        Proc.new{|iterator|
          combiners = {}
          iterator.each do |key, value|
            if combiners.has_key?(key)
              combiners[key] = @__merge_combiners__.call(combiners[key], value)
            else
              combiners[key] = value
            end
          end
          combiners.to_a
        }
      MERGE

      combined = map_partitions(_combine_).attach(merge_value: merge_value, create_combiner: create_combiner)
      shuffled = combined.partitionBy(num_partitions)
      shuffled.map_partitions(_merge_).attach(merge_combiners: merge_combiners)
    end

    #
    # Return a copy of the RDD partitioned using the specified partitioner.
    #
    # rdd = $sc.parallelize(["1","2","3","4","5"]).map(lambda {|x| [x, 1]})
    # rdd.partitionBy(2).glom.collect
    # => [[["3", 1], ["4", 1]], [["1", 1], ["2", 1], ["5", 1]]]
    #
    def partition_by(num_partitions, partition_func=nil)
        num_partitions ||= default_reduce_partitions
        partition_func ||= "lambda{|x| x.hash}"

        _key_function_ = <<-KEY_FUNCTION
          Proc.new{|iterator|
            iterator.map! {|key, value|
              [@__partition_func__.call(key), [key, value]]
            }
          }
        KEY_FUNCTION

        # RDD is transform from [key, value] to [hash, [key, value]]
        keyed = map_partitions(_key_function_).attach(partition_func: partition_func)
        keyed.command.serializer = Spark::Serializer::Pairwise

        # PairwiseRDD and PythonPartitioner are borrowed from Python
        # but works great on ruby too
        pairwise_rdd = PairwiseRDD.new(keyed.jrdd.rdd).asJavaPairRDD
        partitioner = PythonPartitioner.new(num_partitions, partition_func.object_id)
        jrdd = pairwise_rdd.partitionBy(partitioner).values

        # Prev serializer was Pairwise
        rdd = RDD.new(jrdd, context, Spark::Serializer::Simple)
        rdd
    end


    # Aliases
    alias_method :flatMap, :flat_map
    alias_method :mapPartitions, :map_partitions
    alias_method :mapPartitionsWithIndex, :map_partitions_with_index
    alias_method :reduceByKey, :reduce_by_key
    alias_method :combineByKey, :combine_by_key
    alias_method :partitionBy, :partition_by
    alias_method :defaultReducePartitions, :default_reduce_partitions

  end


  class PipelinedRDD < RDD

    attr_reader :prev_jrdd, :serializer, :command

    def initialize(prev, command)

      @command = command

      # if !prev.is_a?(PipelinedRDD) || !prev.pipelinable?
      if prev.is_a?(PipelinedRDD) && prev.pipelinable?
        # Second, ... stages
        @prev_jrdd = prev.prev_jrdd
      else
        # First stage
        @prev_jrdd = prev.jrdd
      end

      @cached = false
      @checkpointed = false

      @context = prev.context
    end

    def pipelinable?
      !(cached? || checkpointed?)
    end

    def jrdd
      return @jrdd_values if @jrdd_values

      command = @command.marshal
      env = @context.environment
      class_tag = @prev_jrdd.classTag

      ruby_rdd = RubyRDD.new(@prev_jrdd.rdd, command, env, Spark.worker_dir, class_tag)
      @jrdd_values = ruby_rdd.asJavaRDD
      @jrdd_values
    end

  end
end
