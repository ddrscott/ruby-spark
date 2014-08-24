require_relative "marshal.rb"

module Spark
  module Serializer
    class MessagePack < Marshal

      def self.serialize(data)
        ::MessagePack::dump(data)
      end

      def self.deserialize(data)
        ::MessagePack::load(data)
      end

    end
  end
end

begin
  require "msgpack"
rescue LoadError
  Spark::Serializer::MessagePack = Spark::Serializer::Marshal
end