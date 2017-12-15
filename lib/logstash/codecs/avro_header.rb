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
# as described in the https://avro.apache.org/docs/1.8.2/spec.html#single_object_encoding[the Avro
# spec].
#
# The length of the header depends on how many bytes are used for a marker and
# the https://avro.apache.org/docs/1.8.2/spec.html#schema_fingerprints[fingerprint
# algorithm]. The fingerprint might be 8 bytes for CRC-64-AVRO, 16 bytes for
# MD5, or 32 bytes for SHA-256.
#
# Another option is the
# https://docs.confluent.io/current/schema-registry/docs/intro.html[Confluent
# Schema Registry], which uses a server to assign ids to different versions of
# schemas and look them up. That's supported by other logstash plugins, e.g.
# https://github.com/revpoint/logstash-codec-avro_schema_registry.
#
# At a minimum, specify the header length, and the plugin will skip those bytes
# before passing the input to the Avro parser.
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
#
# If you specify the header marker, the plugin will attempt to match those
# bytes at the beginning of the data. If they match, it will skip the header
# bytes, otherwise it will pass all the data to the Avro parser.
#
# [source,ruby]
# ----------------------------------
# input {
#   kafka {
#     codec => avro {
#         schema_uri => "/tmp/schema.avsc"
#         header_length => 10
#         # Marker bytes, specified as integer
#         header_marker => [195, 1] # 0xC3, 0x01
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

  # marker bytes at beginning of header, specified as integers
  config :header_marker, :validate => :number, :list => true, :default => []

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
    begin
      binary_data = Base64.strict_decode64(data)
    rescue
      binary_data = data
    end

    datum = StringIO.new(binary_data)
    if header_length > 0
      if binary_data.length < header_length
        @logger.error('message is too small to decode header')
        # Ignore header and try to parse as Avro
      else
        if header_marker and header_marker.length > 0
          marker_length = header_marker.length
          marker = datum.read(marker_length)
          marker_bytes = marker.unpack("C" * marker_length)
          if marker_bytes == header_marker
            hash_length = header_length - marker_length
            if hash_length > 0
              datum.read(hash_length)
              # TODO: look up schema using hash
            end
          else
            @logger.error('header marker mismatch')
            # Assume that there is no header and try to parse as Avro
            datum.rewind
          end
        else
          # No marker, just read header and ignore it
          datum.read(header_length)
        end
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
