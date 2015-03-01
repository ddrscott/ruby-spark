package org.apache.spark.api.ruby

import java.io.{DataInputStream, DataOutputStream, ByteArrayInputStream}

import scala.collection.mutable.ArrayBuffer
import scala.collection.JavaConverters._
import scala.reflect.{ClassTag, classTag}

import org.apache.spark.api.java.JavaRDD
import org.apache.spark.mllib.regression.LabeledPoint
import org.apache.spark.mllib.linalg.{Vector, DenseVector, SparseVector}


/* =================================================================================================
 * object RubySerializer
 * =================================================================================================
 */
object RubySerializer {

  /**
   * Convert an RDD of serialized Ruby objects to RDD of objects, that is usable in Java.
   */
  def rubyToJava(rbRDD: JavaRDD[Array[Byte]], batched: Boolean): JavaRDD[Any] = {
    rbRDD.rdd.mapPartitions { iter =>
      iter.flatMap { item =>

        val obj = Marshal.load(item)
        if(batched){
          obj.asInstanceOf[Array[_]]
        }
        else{
          Seq(item)
        }

      }
    }.toJavaRDD()
  }

}


/* =================================================================================================
 * class Marshal
 * =================================================================================================
 */
class Marshal(is: DataInputStream) {

  case class WaitForObject()

  val registeredSymbols = ArrayBuffer[String]()
  val registeredLinks = ArrayBuffer[Any]()

  def load: Any = {
    load(is.readUnsignedByte.toChar)
  }

  def load(dataType: Char): Any = {
    dataType match {
      case '0' => null
      case 'T' => true
      case 'F' => false
      case 'i' => loadInt
      case 'f' => loadAndRegisterFloat
      case ':' => loadAndRegisterSymbol
      case '[' => loadAndRegisterArray
      case 'U' => loadAndRegisterUserObject
      case _ =>
        throw new IllegalArgumentException(s"Format is not supported: $dataType.")
    }
  }


  // ----------------------------------------------------------------------------------------------
  // Load by type

  def loadInt: Int = {
    var c = is.readByte.toInt

    if (c == 0) {
      return 0
    } else if (4 < c && c < 128) {
      return c - 5
    } else if (-129 < c && c < -4) {
      return c + 5
    }

    var result: Long = 0

    if (c > 0) {
      result = 0
      for( i <- 0 until c ) {
        result |= (is.readUnsignedByte << (8 * i)).toLong
      }
    } else {
      c = -c
      result = -1
      for( i <- 0 until c ) {
        result &= ~((0xff << (8 * i)).toLong)
        result |= (is.readUnsignedByte << (8 * i)).toLong
      }
    }

    result.toInt
  }

  def loadAndRegisterFloat: Double = {
    val result = loadFloat
    registeredLinks += result
    result
  }

  def loadFloat: Double = {
    val string = loadString
    string match {
      case "nan"  => Double.NaN
      case "inf"  => Double.PositiveInfinity
      case "-inf" => Double.NegativeInfinity
      case _ => string.toDouble
    }
  }

  def loadString: String = {
    new String(loadStringBytes)
  }

  def loadStringBytes: Array[Byte] = {
    val size = loadInt
    val buffer = new Array[Byte](size)

    var readSize = 0
    while(readSize < size){
      val read = is.read(buffer, readSize, size-readSize)

      if(read == -1){
        throw new IllegalArgumentException("Marshal too short.")
      }

      readSize += read
    }

    buffer
  }

  def loadAndRegisterSymbol: String = {
    val result = loadString
    registeredSymbols += result
    result
  }

  def loadAndRegisterArray: Array[Any] = {
    val size = loadInt
    val array = new Array[Any](size)

    registeredLinks += array

    for( i <- 0 until size ) {
      array(i) = loadNextObject
    }

    array
  }

  def loadAndRegisterUserObject: Any = {
    val klass = loadNextObject.asInstanceOf[String]

    // Register future class before load the next object
    registeredLinks += WaitForObject()
    val index = registeredLinks.size - 1

    val data = loadNextObject

    val result = klass match {
      case "Spark::Mllib::LabeledPoint" => createLabeledPoint(data)
      case "Spark::Mllib::DenseVector" => createDenseVector(data)
      case other =>
        throw new IllegalArgumentException(s"Object $other is not supported.")
    }

    registeredLinks(index) = result

    result
  }


  // ----------------------------------------------------------------------------------------------
  // Other loads

  def loadNextObject: Any = {
    val dataType = is.readUnsignedByte.toChar

    if(isLinkType(dataType)){
      readLink(dataType)
    }
    else{
      load(dataType)
    }
  }


  // ----------------------------------------------------------------------------------------------
  // To java objects

  def createLabeledPoint(data: Any): LabeledPoint = {
    val array = data.asInstanceOf[Array[_]]
    new LabeledPoint(array(0).asInstanceOf[Double], array(1).asInstanceOf[Vector])
  }

  def createDenseVector(data: Any): DenseVector = {
    new DenseVector(data.asInstanceOf[Array[_]].map(_.asInstanceOf[Double]))
  }


  // ----------------------------------------------------------------------------------------------
  // Cache

  def readLink(dataType: Char): Any = {
    val index = loadInt

    dataType match {
      case '@' => registeredLinks(index)
      case ';' => registeredSymbols(index)
    }
  }

  def isLinkType(dataType: Char): Boolean = {
    dataType == ';' || dataType == '@'
  }

}


/* =================================================================================================
 * object Marshal
 * =================================================================================================
 */
object Marshal {
  def load(bytes: Array[Byte]) = {
    val is = new DataInputStream(new ByteArrayInputStream(bytes))

    val majorVersion = is.readUnsignedByte // 4
    val minorVersion = is.readUnsignedByte // 8

    (new Marshal(is)).load
  }
}