# frozen_string_literal: true

class ActivityPub::ProcessStatusService < BaseService
  include JsonLdHelper

  def call(status, json)
    @json                      = json
    @uri                       = @json['id']
    @status                    = status
    @account                   = status.account
    @media_attachments_changed = false

    return unless expected_type?

    # Lock to only allow processing one create/update per
    # status at a time. TODO: What if updates come out of order?
    RedisLock.acquire(lock_options) do |lock|
      if lock.acquired?
        Status.transaction do
          create_previous_edit!
          update_media_attachments!
          update_poll!
          update_immediate_attributes!
          update_metadata!
          create_edit!
        end
      else
        raise Mastodon::RaceConditionError
      end
    end
  end

  private

  def update_media_attachments!
    previous_media_attachments = @status.media_attachments.to_a
    next_media_attachments     = []

    as_array(@json['attachment']).each do |attachment|
      next if attachment['url'].blank? || next_media_attachments.size > 4

      begin
        href = Addressable::URI.parse(attachment['url']).normalize.to_s

        media_attachment   = previous_media_attachments.find { |previous_media_attachment| previous_media_attachment.remote_url == href }
        media_attachment ||= MediaAttachment.new(account: @account, remote_url: href)

        media_attachment.description          = attachment['summary'].presence || attachment['name'].presence
        media_attachment.focus                = attachment['focalPoint']
        media_attachment.thumbnail_remote_url = icon_url_from_attachment(attachment)
        media_attachment.save

        next_media_attachments << media_attachment

        # TODO: Check for skip_download? here

        RedownloadMediaWorker.perform_async(media_attachment.id) if media_attachment.remote_url_previously_changed? || media_attachment.thumbnail_remote_url_previously_changed?
      rescue Addressable::URI::InvalidURIError => e
        Rails.logger.debug "Invalid URL in attachment: #{e}"
      end
    end

    removed_media_attachments = previous_media_attachments - next_media_attachments

    MediaAttachment.where(id: removed_media_attachments.map(&:id)).update_all(status_id: nil)
    MediaAttachment.where(id: next_media_attachments.map(&:id)).update_all(status_id: @status.id)

    @media_attachments_changed = true if previous_media_attachments != @status.media_attachments
  end

  def update_poll!
    previous_poll = @status.poll

    if equals_or_includes?(@json['type'], 'Question')
      # TODO: Update or add poll
    else
      previous_poll&.destroy
    end

    @media_attachments_changed = true if previous_poll != @status.poll
  end

  def update_immediate_attributes!
    @status.text         = text_from_content || ''
    @status.spoiler_text = text_from_summary || ''
    @status.sensitive    = @account.sensitized? || @json['sensitive'] || false
    @status.language     = language_from_content
    @status.edited_at    = @json['updated'] || Time.now.utc
    @status.save
  end

  def update_metadata!
    raw_tags     = []
    raw_mentions = []
    raw_emojis   = []

    as_array(@json['tag']).each do |tag|
      if equals_or_includes?(tag['type'], 'Hashtag')
        raw_tags << tag['name']
      elsif equals_or_includes?(tag['type'], 'Mention')
        raw_mentions << tag['href']
      elsif equals_or_includes?(tag['type'], 'Emoji')
        raw_emojis << tag
      end
    end

    @status.tags = Tag.find_or_create_by_names(raw_tags)

    # TODO: Update mentions, emojis
  end

  def expected_type?
    equals_or_includes_any?(@json['type'], %w(Note Question))
  end

  def lock_options
    { redis: Redis.current, key: "create:#{@uri}", autorelease: 15.minutes.seconds }
  end

  def text_from_content
    if @json['content'].present?
      @json['content']
    elsif content_language_map?
      @json['contentMap'].values.first
    end
  end

  def content_language_map?
    @json['contentMap'].is_a?(Hash) && !@json['contentMap'].empty?
  end

  def text_from_summary
    if @json['summary'].present?
      @json['summary']
    elsif summary_language_map?
      @json['summaryMap'].values.first
    end
  end

  def summary_language_map?
    @json['summaryMap'].is_a?(Hash) && !@json['summaryMap'].empty?
  end

  def language_from_content
    if content_language_map?
      @json['contentMap'].keys.first
    elsif summary_language_map?
      @json['summaryMap'].keys.first
    else
      'und'
    end
  end

  def icon_url_from_attachment(attachment)
    url = begin
      if attachment['icon'].is_a?(Hash)
        attachment['icon']['url']
      else
        attachment['icon']
      end
    end

    return if url.blank?

    Addressable::URI.parse(url).normalize.to_s
  rescue Addressable::URI::InvalidURIError
    nil
  end

  def create_previous_edit!
    # We only need to create a previous edit when no previous edits exist, e.g.
    # when the status has never been edited. For other cases, we always create
    # an edit, so the step can be skipped

    return if @status.edits.any?

    @status.edits.create(
      text: @status.text,
      spoiler_text: @status.spoiler_text,
      media_attachments_changed: false,
      account_id: @status.account_id,
      created_at: @status.created_at
    )
  end

  def create_edit!
    @status_edit = @status.edits.create(
      text: @status.text,
      spoiler_text: @status.spoiler_text,
      media_attachments_changed: @media_attachments_changed,
      account_id: @status.account_id,
      created_at: @status.edited_at
    )
  end
end
