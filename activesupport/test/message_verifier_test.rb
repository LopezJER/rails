# frozen_string_literal: true

require_relative "abstract_unit"
require "openssl"
require "active_support/time"
require "active_support/json"
require_relative "metadata/shared_metadata_tests"

class MessageVerifierTest < ActiveSupport::TestCase
  class JSONSerializer
    def dump(value)
      ActiveSupport::JSON.encode(value)
    end

    def load(value)
      ActiveSupport::JSON.decode(value)
    end
  end

  def setup
    @verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!")
    @data = { "some" => "data", "now" => Time.utc(2010) }
    @secret = SecureRandom.random_bytes(32)
  end

  def test_valid_message
    data, hash = @verifier.generate(@data).split("--")
    assert_not @verifier.valid_message?(nil)
    assert_not @verifier.valid_message?("")
    assert_not @verifier.valid_message?("\xff") # invalid encoding
    assert_not @verifier.valid_message?("#{data.reverse}--#{hash}")
    assert_not @verifier.valid_message?("#{data}--#{hash.reverse}")
    assert_not @verifier.valid_message?("purejunk")
  end

  def test_simple_round_tripping
    message = @verifier.generate(@data)
    assert_equal @data, @verifier.verified(message)
    assert_equal @data, @verifier.verify(message)
  end

  def test_verified_returns_false_on_invalid_message
    assert_not @verifier.verified("purejunk")
  end

  def test_verify_exception_on_invalid_message
    assert_raise(ActiveSupport::MessageVerifier::InvalidSignature) do
      @verifier.verify("purejunk")
    end
  end

  test "supports URL-safe encoding" do
    verifier = ActiveSupport::MessageVerifier.new(@secret, urlsafe: true, serializer: JSON)

    # To verify that the message payload uses a URL-safe encoding (i.e. does not
    # use "+" or "/"), the unencoded bytes should have a 6-bit aligned
    # occurrence of `0b111110` or `0b111111`.  Also, to verify that the message
    # payload is unpadded, the number of unencoded bytes should not be a
    # multiple of 3.
    #
    # The JSON serializer adds quotes around strings, adding 1 byte before and
    # 1 byte after the input string.  So we choose an input string of "??",
    # which is serialized as:
    #   00100010 00111111 00111111 00100010
    # Which is 6-bit aligned as:
    #   001000 100011 111100 111111 001000 10xxxx
    data = "??"
    message = verifier.generate(data)

    assert_equal data, verifier.verified(message)
    assert_equal message, URI.encode_www_form_component(message)
    assert_not_equal 0, message.rpartition("--").first.length % 4,
      "Unable to assert that the message payload is unpadded, because it does not require padding"
  end

  def test_alternative_serialization_method
    prev = ActiveSupport.use_standard_json_time_format
    ActiveSupport.use_standard_json_time_format = true
    verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!", serializer: JSONSerializer.new)
    message = verifier.generate({ :foo => 123, "bar" => Time.utc(2010) })
    exp = { "foo" => 123, "bar" => "2010-01-01T00:00:00.000Z" }
    assert_equal exp, verifier.verified(message)
    assert_equal exp, verifier.verify(message)
  ensure
    ActiveSupport.use_standard_json_time_format = prev
  end

  def test_verify_with_parse_json_times
    previous = [ ActiveSupport.parse_json_times, Time.zone ]
    ActiveSupport.parse_json_times, Time.zone = true, "UTC"

    assert_equal "hi", @verifier.verify(@verifier.generate("hi", expires_at: Time.now.utc + 10))
  ensure
    ActiveSupport.parse_json_times, Time.zone = previous
  end

  def test_raise_error_when_secret_is_nil
    exception = assert_raise(ArgumentError) do
      ActiveSupport::MessageVerifier.new(nil)
    end
    assert_equal "Secret should not be nil.", exception.message
  end

  def test_rotating_secret
    old_message = ActiveSupport::MessageVerifier.new("old", digest: "SHA1").generate("old")

    verifier = ActiveSupport::MessageVerifier.new(@secret, digest: "SHA1")
    verifier.rotate "old"

    assert_equal "old", verifier.verified(old_message)
  end

  def test_multiple_rotations
    old_message   = ActiveSupport::MessageVerifier.new("old", digest: "SHA256").generate("old")
    older_message = ActiveSupport::MessageVerifier.new("older", digest: "SHA1").generate("older")

    verifier = ActiveSupport::MessageVerifier.new(@secret, digest: "SHA512")
    verifier.rotate "old",   digest: "SHA256"
    verifier.rotate "older", digest: "SHA1"

    assert_equal "new",   verifier.verified(verifier.generate("new"))
    assert_equal "old",   verifier.verified(old_message)
    assert_equal "older", verifier.verified(older_message)
  end

  def test_rotations_with_metadata
    old_message = ActiveSupport::MessageVerifier.new("old").generate("old", purpose: :rotation)

    verifier = ActiveSupport::MessageVerifier.new(@secret)
    verifier.rotate "old"

    assert_equal "old", verifier.verified(old_message, purpose: :rotation)
  end
end

class DefaultMarshalSerializerMessageVerifierTest < MessageVerifierTest
  def setup
    @default_verifier = ActiveSupport::MessageVerifier.default_message_verifier_serializer
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = :marshal

    @verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!")
    @data = { some: "data", now: Time.utc(2010) }
    @secret = SecureRandom.random_bytes(32)
  end

  def teardown
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = @default_verifier
  end

  def test_backward_compatibility_messages_signed_without_metadata
    signed_message = "BAh7BzoJc29tZUkiCWRhdGEGOgZFVDoIbm93SXU6CVRpbWUNIIAbgAAAAAAHOgtvZmZzZXRpADoJem9uZUkiCFVUQwY7BkY=--d03c52c91dfe4ccc5159417c660461bcce005e96"
    assert_equal @data, @verifier.verify(signed_message)
  end

  def test_on_rotation_is_called_and_verified_returns_message
    older_message = ActiveSupport::MessageVerifier.new("older", digest: "SHA1").generate({ encoded: "message" })

    verifier = ActiveSupport::MessageVerifier.new(@secret, digest: "SHA512")
    verifier.rotate "old",   digest: "SHA256"
    verifier.rotate "older", digest: "SHA1"

    rotated = false
    message = verifier.verified(older_message, on_rotation: proc { rotated = true })

    assert_equal({ encoded: "message" }, message)
    assert rotated
  end

  def test_raise_error_when_argument_class_is_not_loaded
    # To generate the valid message below:
    #
    #   AutoloadClass = Struct.new(:foo)
    #   valid_message = @verifier.generate(foo: AutoloadClass.new('foo'))
    #
    valid_message = "BAh7BjoIZm9vbzonTWVzc2FnZVZlcmlmaWVyVGVzdDo6QXV0b2xvYWRDbGFzcwY6CUBmb29JIghmb28GOgZFVA==--f3ef39a5241c365083770566dc7a9eb5d6ace914"
    exception = assert_raise(ArgumentError, NameError) do
      @verifier.verified(valid_message)
    end
    assert_includes ["uninitialized constant MessageVerifierTest::AutoloadClass",
                    "undefined class/module MessageVerifierTest::AutoloadClass"], exception.message
    exception = assert_raise(ArgumentError, NameError) do
      @verifier.verify(valid_message)
    end
    assert_includes ["uninitialized constant MessageVerifierTest::AutoloadClass",
                    "undefined class/module MessageVerifierTest::AutoloadClass"], exception.message
  end
end

class MarshalSerializeAndFallbackMessageVerifierTest < DefaultMarshalSerializerMessageVerifierTest
  def setup
    @default_verifier = ActiveSupport::MessageVerifier.default_message_verifier_serializer
    @default_use_marshal = ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization
    @default_fallback = ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = :hybrid
    ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization = true
    ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization = true

    @verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!")
    @data = { some: "data", now: Time.utc(2010) }
    @secret = SecureRandom.random_bytes(32)
  end

  def teardown
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = @default_verifier
    ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization = @default_use_marshal
    ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization = @default_fallback
  end
end

class JsonSerializeMarshalFallbackMessageVerifierTest < MessageVerifierTest
  def setup
    @default_verifier = ActiveSupport::MessageVerifier.default_message_verifier_serializer
    @default_use_marshal = ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization
    @default_fallback = ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = :hybrid
    ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization = false
    ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization = true

    @verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!")
    @data = { "some" => "data", "now" => Time.utc(2010) }
    @secret = SecureRandom.random_bytes(32)
  end

  def teardown
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = @default_verifier
    ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization = @default_use_marshal
    ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization = @default_fallback
  end

  def test_on_rotation_is_called_and_verified_returns_message
    older_message = ActiveSupport::MessageVerifier.new("older", digest: "SHA1").generate({ encoded: "message" })

    verifier = ActiveSupport::MessageVerifier.new(@secret, digest: "SHA512")
    verifier.rotate "old",   digest: "SHA256"
    verifier.rotate "older", digest: "SHA1"

    rotated = false
    message = verifier.verified(older_message, on_rotation: proc { rotated = true })

    assert_equal({ "encoded" => "message" }, message)
    assert rotated
  end

  def test_backward_compatibility_messages_signed_marshal_serialized
    marshal_serialized_signed_message = "BAh7B0kiCXNvbWUGOgZFVEkiCWRhdGEGOwBUSSIIbm93BjsAVEl1OglUaW1lDSCAG8AAAAAABjoJem9uZUkiCFVUQwY7AEY=--ae7480422168507f4a8aec6b1d68bfdfd5c6ef48"
    assert_equal @data, @verifier.verify(marshal_serialized_signed_message)
  end
end

class JsonSerializeAndNoFallbackMessageVerifierTest < JsonSerializeMarshalFallbackMessageVerifierTest
  def setup
    @default_verifier = ActiveSupport::MessageVerifier.default_message_verifier_serializer
    @default_use_marshal = ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization
    @default_fallback = ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = :hybrid
    ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization = false
    ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization = false

    @verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!")
    @data = { "some" => "data", "now" => Time.utc(2010) }
    @secret = SecureRandom.random_bytes(32)
  end

  def teardown
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = @default_verifier
    ActiveSupport::JsonWithMarshalFallback.use_marshal_serialization = @default_use_marshal
    ActiveSupport::JsonWithMarshalFallback.fallback_to_marshal_deserialization = @default_fallback
  end

  def test_backward_compatibility_messages_signed_marshal_serialized
    marshal_serialized_signed_message = "BAh7B0kiCXNvbWUGOgZFVEkiCWRhdGEGOwBUSSIIbm93BjsAVEl1OglUaW1lDSCAG8AAAAAABjoJem9uZUkiCFVUQwY7AEY=--ae7480422168507f4a8aec6b1d68bfdfd5c6ef48"
    assert_raise(JSON::ParserError) do
      @verifier.verify(marshal_serialized_signed_message)
    end
  end
end

class DefaultJsonSerializerMessageVerifierTest < JsonSerializeAndNoFallbackMessageVerifierTest
  def setup
    @default_verifier = ActiveSupport::MessageVerifier.default_message_verifier_serializer
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = :json

    @verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!")
    @data = { "some" => "data", "now" => Time.utc(2010) }
    @secret = SecureRandom.random_bytes(32)
  end

  def teardown
    ActiveSupport::MessageVerifier.default_message_verifier_serializer = @default_verifier
  end
end

class MessageVerifierMetadataTest < ActiveSupport::TestCase
  include SharedMessageMetadataTests

  setup do
    @verifier = ActiveSupport::MessageVerifier.new("Hey, I'm a secret!", **verifier_options)
  end

  def test_verify_raises_when_purpose_differs
    assert_raise(ActiveSupport::MessageVerifier::InvalidSignature) do
      @verifier.verify(generate(data, purpose: "payment"), purpose: "shipping")
    end
  end

  def test_verify_with_use_standard_json_time_format_as_false
    format_before = ActiveSupport.use_standard_json_time_format
    ActiveSupport.use_standard_json_time_format = false
    assert_equal "My Name", @verifier.verify(generate("My Name"))
  ensure
    ActiveSupport.use_standard_json_time_format = format_before
  end

  def test_verify_raises_when_expired
    signed_message = generate(data, expires_in: 1.month)

    travel 2.months
    assert_raise(ActiveSupport::MessageVerifier::InvalidSignature) do
      @verifier.verify(signed_message)
    end
  end

  private
    def generate(message, **options)
      @verifier.generate(message, **options)
    end

    def parse(message, **options)
      @verifier.verified(message, **options)
    end

    def verifier_options
      Hash.new
    end
end

class MessageVerifierMetadataMarshalTest < MessageVerifierMetadataTest
  private
    def verifier_options
      { serializer: Marshal }
    end
end

class MessageVerifierMetadataJsonWithMarshalFallbackTest < MessageVerifierMetadataTest
  private
    def verifier_options
      { serializer: ActiveSupport::JsonWithMarshalFallback }
    end
end

class MessageVerifierMetadataJsonTest < MessageVerifierMetadataTest
  private
    def verifier_options
      { serializer: JSON }
    end
end


class MessageVerifierMetadataCustomJSONTest < MessageVerifierMetadataTest
  private
    def verifier_options
      { serializer: MessageVerifierTest::JSONSerializer.new }
    end
end

class MessageEncryptorMetadataNullSerializerTest < MessageVerifierMetadataTest
  private
    def data
      "string message"
    end

    def null_serializing?
      true
    end

    def verifier_options
      { serializer: ActiveSupport::MessageEncryptor::NullSerializer }
    end
end
