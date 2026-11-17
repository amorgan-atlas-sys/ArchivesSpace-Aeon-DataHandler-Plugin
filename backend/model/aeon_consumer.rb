# A consumer is a named application/integration (for example the ASpace
# client addon's instance import). Consumers are independent partitions of
# the mapping structure: rules belong to exactly one consumer and there is
# no fallback between consumers. Seeded consumers ship with protected: true —
# their labels and rules are editable but they cannot be deleted and their
# keys are immutable (addons reference the key in the `consumer` query param).
class AeonConsumer < Sequel::Model(:aeon_consumers)
  KEY_FORMAT = /\A[a-z0-9][a-z0-9_-]*\z/.freeze

  one_to_many :rules,
              class: :AeonFieldMapping,
              key: :consumer_id

  # Resolve a request's consumer key to [consumer, error_message]. Exactly
  # one of the pair is nil. Missing and unknown keys fail with a message —
  # no silent fallback to another consumer's mappings; a typo must fail
  # loudly, not quietly serve the wrong rule set. The controller helper
  # (aeon_consumer_or_halt) turns the message into a 400. Lives here, not in
  # the Sinatra helper, so the logic is testable outside ArchivesSpace.
  def self.resolve_key(consumer_key)
    key = consumer_key.to_s.strip
    return [nil, "consumer parameter is required"] if key.empty?

    consumer = where(consumer_key: key).first
    if consumer.nil?
      return [nil, "Unknown consumer: #{key}. Create it on the Aeon Mapping page (Plug-ins menu)."]
    end

    [consumer, nil]
  end

  # Column sizes in the aeon_consumers table (setup migration). Checked here so
  # an over-long value gets a readable 400 instead of a raw DB error.
  KEY_MAX_LENGTH   = 100
  LABEL_MAX_LENGTH = 255

  def validate
    super
    if consumer_key.nil? || consumer_key.strip.empty?
      errors.add(:consumer_key, "is required")
    elsif !KEY_FORMAT.match?(consumer_key)
      errors.add(:consumer_key, "must start with a lowercase letter or digit and contain only lowercase letters, digits, hyphens, and underscores")
    elsif consumer_key.length > KEY_MAX_LENGTH
      errors.add(:consumer_key, "must be #{KEY_MAX_LENGTH} characters or fewer")
    end

    if label.nil? || label.strip.empty?
      errors.add(:label, "is required")
    elsif label.length > LABEL_MAX_LENGTH
      errors.add(:label, "must be #{LABEL_MAX_LENGTH} characters or fewer")
    end
  end
end
