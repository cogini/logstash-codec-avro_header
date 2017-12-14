# encoding: utf-8
require "open-uri"
require "avro"
require "base64"
require "logstash/codecs/base"
require "logstash/event"
require "logstash/timestamp"
require "logstash/util"

# Read serialized Avro records as Logstash events
#
# This plugin is used to serialize Logstash events as
# Avro datums, as well as deserializing Avro datums into
# Logstash events.
#
# ==== Encoding
#
# This codec is for serializing individual Logstash events
# as Avro datums that are Avro binary blobs. It does not encode
# Logstash events into an Avro file.
#
#
# ==== Decoding
#
# This codec is for deserializing individual Avro records. It is not for reading
# Avro files. Avro files have a unique format that must be handled upon input.
#
#
# ==== Usage
# To read messages from Kafka input:
#
# [source,ruby]
# ----------------------------------
# input {
#   kafka {
#     codec => avro {
#         schema_uri => "/tmp/schema.avsc"
#     }
#   }
# }
# filter {
#   ...
# }
# output {
#   ...
# }
# ----------------------------------
#
# Avro messages may have a header before the binary data indicating the schema,
# as described in the
# https://avro.apache.org/docs/1.8.2/spec.html#single_object_encoding[the Avro
# spec].
#
# The length of the prefix depends on how many bytes are used as the marker
# and the fingerprint algorithm.
#
# [source,ruby]
# ----------------------------------
# input {
#   kafka {
#     codec => avro {
#         schema_uri => "/tmp/schema.avsc"
#         header_length => 10
#     }
#   }
# }
# ----------------------------------
class LogStash::Codecs::AvroHeader < LogStash::Codecs::Base
  config_name "avro_header"


  # schema path to fetch the schema from.
  # This can be a 'http' or 'file' scheme URI
  # example:
  #
  # * http - `http://example.com/schema.avsc`
  # * file - `/path/to/schema.avsc`
  config :schema_uri, :validate => :string, :required => true

  # number of header bytes to skip before the Avro data
  config :header_length, :validate => :number, :default => 0

  # tag events with `_avroparsefailure` when decode fails
  config :tag_on_failure, :validate => :boolean, :default => false

  def open_and_read(uri_string)
    open(uri_string).read
  end

  public
  def register
    @schema = Avro::Schema.parse(open_and_read(schema_uri))
  end

  public
  def decode(data)
    datum = StringIO.new(Base64.strict_decode64(data)) rescue StringIO.new(data)
    if header_length > 0
      if data.length < header_length
        @logger.error('message is too small to decode header')
      else
        datum.read(header_length)
      end
    end
    decoder = Avro::IO::BinaryDecoder.new(datum)
    datum_reader = Avro::IO::DatumReader.new(@schema)
    yield LogStash::Event.new(datum_reader.read(decoder))
  rescue => e
    if tag_on_failure
      @logger.error("Avro parse error, original data now in message field", :error => e)
      yield LogStash::Event.new("message" => data, "tags" => ["_avroparsefailure"])
    else
      raise e
    end
  end

  public
  def encode(event)
    dw = Avro::IO::DatumWriter.new(@schema)
    buffer = StringIO.new
    encoder = Avro::IO::BinaryEncoder.new(buffer)
    dw.write(event.to_hash, encoder)
    @on_event.call(event, Base64.strict_encode64(buffer.string))
  end

end
