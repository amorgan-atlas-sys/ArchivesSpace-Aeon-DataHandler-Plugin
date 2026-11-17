require_relative "../spec_helper"

RSpec.describe AeonConsumer do
  def consumer(attrs = {})
    AeonConsumer.new({ consumer_key: "my_app", label: "My App" }.merge(attrs))
  end

  describe "#validate" do
    it "accepts a well-formed key and label" do
      expect(consumer).to be_valid
    end

    it "requires a key" do
      record = consumer(consumer_key: "   ")
      expect(record).not_to be_valid
      expect(record.errors[:consumer_key].join).to include("required")
    end

    it "rejects a key with invalid characters" do
      expect(consumer(consumer_key: "My App!")).not_to be_valid
    end

    it "rejects a key longer than the column length" do
      record = consumer(consumer_key: "a" * (AeonConsumer::KEY_MAX_LENGTH + 1))
      expect(record).not_to be_valid
      expect(record.errors[:consumer_key].join).to include("#{AeonConsumer::KEY_MAX_LENGTH} characters")
    end

    it "accepts a key at exactly the column length" do
      expect(consumer(consumer_key: "a" * AeonConsumer::KEY_MAX_LENGTH)).to be_valid
    end

    it "requires a label" do
      record = consumer(label: "   ")
      expect(record).not_to be_valid
      expect(record.errors[:label].join).to include("required")
    end

    it "rejects a label longer than the column length" do
      record = consumer(label: "x" * (AeonConsumer::LABEL_MAX_LENGTH + 1))
      expect(record).not_to be_valid
      expect(record.errors[:label].join).to include("#{AeonConsumer::LABEL_MAX_LENGTH} characters")
    end

    it "accepts a label at exactly the column length" do
      expect(consumer(label: "x" * AeonConsumer::LABEL_MAX_LENGTH)).to be_valid
    end
  end

  describe ".resolve_key" do
    it "returns an error when the key is missing" do
      record, error = AeonConsumer.resolve_key(nil)
      expect(record).to be_nil
      expect(error).to eq("consumer parameter is required")
    end

    it "returns an error when the key is blank" do
      record, error = AeonConsumer.resolve_key("   ")
      expect(record).to be_nil
      expect(error).to eq("consumer parameter is required")
    end

    it "returns an error naming an unknown key" do
      allow(AeonConsumer).to receive(:where).with(consumer_key: "nope").and_return([])
      record, error = AeonConsumer.resolve_key("nope")
      expect(record).to be_nil
      expect(error).to include("Unknown consumer: nope")
    end

    it "returns the consumer for a known key, ignoring surrounding whitespace" do
      known = consumer
      allow(AeonConsumer).to receive(:where).with(consumer_key: "my_app").and_return([known])
      record, error = AeonConsumer.resolve_key("  my_app  ")
      expect(record).to be(known)
      expect(error).to be_nil
    end
  end
end
