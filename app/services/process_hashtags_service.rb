# frozen_string_literal: true

class ProcessHashtagsService < BaseService
  def call(status, raw_tags = [])
    @status        = status
    @account       = status.account
    @raw_tags      = status.local? ? Extractor.extract_hashtags(status.text) : raw_tags
    @previous_tags = status.tags.to_a
    @current_tags  = []

    assign_tags!
    update_featured_tags!
  end

  private

  def assign_tags!
    Tag.find_or_create_by_names(@raw_tags) do |tag|
      @current_tags << tag

      next if @previous_tags.include?(tag)

      @status.tags << tag
      tag.use!(@account, status: @status, at_time: @status.created_at) if @status.public_visibility?
    end
  end

  def update_featured_tags!
    return unless @status.distributable?

    added_tags = @current_tags - @previous_tags

    unless added_tags.empty?
      @account.featured_tags.where(tag_id: added_tags.map(&:id)).each do |featured_tag|
        featured_tag.increment(@status.created_at)
      end
    end

    removed_tags = @previous_tags - @current_tags

    unless removed_tags.empty?
      @account.featured_tags.where(tag_id: removed_tags.map(&:id)).each do |featured_tag|
        featured_tag.decrement(@status.id)
      end
    end
  end
end
