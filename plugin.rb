# frozen_string_literal: true

# name: dm-wb-cms-oauth2-group-sync
# about: Sync Discourse groups based on WB CMS subscription status from OAuth2 token response
# version: 0.1.2
# authors: Jahan Gagan
# url: https://github.com/jahan-ggn/dm-wb-cms-oauth2-group-sync

enabled_site_setting :dm_WB_CMS_oauth2_group_sync_enabled

module ::DmWbCmsOauth2GroupSync
  PLUGIN_NAME = "dm-wb-cms-oauth2-group-sync"
  STORE_KEY   = "dm_wb_cms_oauth2_group_sync"
end

require_relative "lib/dm_wb_cms_oauth2_group_sync/engine"

after_initialize do
  module ::WbCmsGroupSync
    INSIDER_GROUP     = "insider"
    NON_INSIDER_GROUP = "non-insider"

    class << self
      def sync_user(user, wb_user)
        return unless user && wb_user
        return unless SiteSetting.dm_WB_CMS_oauth2_group_sync_enabled

        insider, non_insider = fetch_groups
        return log_groups_missing unless insider && non_insider

        active = subscription_active?(wb_user.dig("subscriptions"))
        before_groups = user.groups.pluck(:name)

        if active 
          insider.add(user) if user.groups.exclude?(insider) 
          non_insider.remove(user) if user.groups.include?(non_insider) 
        else 
          non_insider.add(user) if user.groups.exclude?(non_insider) 
          insider.remove(user) if user.groups.include?(insider) 
        end

        after_groups = user.groups.pluck(:name)
        log_sync_result(user, before_groups, after_groups, active)
      end

      def subscription_active?(subscriptions)
        return false unless subscriptions.is_a?(Hash)
        insider_list = subscriptions["insider"] || subscriptions[:insider]
        return false unless insider_list.is_a?(Array) && insider_list.any?
        status = insider_list.first["status"] || insider_list.first[:status]
        status.to_i == 1
      end

      private

      def fetch_groups
        [
          Group.find_by(name: INSIDER_GROUP),
          Group.find_by(name: NON_INSIDER_GROUP)
        ]
      end

      def log_groups_missing
        return unless SiteSetting.oauth2_debug_auth
        Rails.logger.debug <<-LOG
          [WB CMS] Group Sync: required groups missing.
          - #{INSIDER_GROUP}: #{Group.exists?(name: INSIDER_GROUP)}
          - #{NON_INSIDER_GROUP}: #{Group.exists?(name: NON_INSIDER_GROUP)}
          No changes applied. Create both groups and retry.
        LOG
      end

      def log_sync_result(user, before, after, active)
        return unless SiteSetting.oauth2_debug_auth
        status_str = active ? "ACTIVE (status=1)" : "INACTIVE/NONE (status!=1 or missing)"
        Rails.logger.debug <<-LOG
          [WB CMS] Group Sync Applied
          User: #{user.username} (id=#{user.id})
          Subscription: #{status_str}
          Before: #{before.sort.join(', ').presence || '(none)'}
          After:  #{after.sort.join(', ').presence || '(none)'}
        LOG
      end
    end
  end

  module ::WbCmsOauth2BasicExtraPatch
    def extra
      base = super || {}
      raw_user = access_token&.params&.dig("user") || access_token&.params&.dig(:user)
      wb_user  = raw_user.is_a?(Hash) ? raw_user : raw_user&.to_h

      data = base.dup
      data[:wb_user] = wb_user if wb_user

      if SiteSetting.oauth2_debug_auth
        Rails.logger.debug(wb_user ? "[WB CMS] extra: wb_user extracted" : "[WB CMS] extra: wb_user missing in token params")
      end

      data
    end
  end

  if defined?(::OmniAuth::Strategies::Oauth2Basic)
    ::OmniAuth::Strategies::Oauth2Basic.prepend(::WbCmsOauth2BasicExtraPatch)
  else
    Rails.logger.debug("[WB CMS] Strategy Oauth2Basic not found — cannot patch extra()") if SiteSetting.oauth2_debug_auth
  end

  module ::WbCmsAfterAuthenticateGroupSync
    def after_authenticate(auth, existing_account: nil)
      result = super
      return result unless SiteSetting.dm_WB_CMS_oauth2_group_sync_enabled

      wb_user = auth[:extra]&.[](:wb_user)
      return result unless wb_user

      user = result.user

      if user.present?
        ::WbCmsGroupSync.sync_user(user, wb_user)
        log_info("Synced existing user #{user.username} (#{user.email}) via OAuth2")
      else
        email = wb_user["loginName"]&.strip&.downcase
        return result unless email
        
        PluginStore.set(::DmWbCmsOauth2GroupSync::STORE_KEY, "pending_#{email}", wb_user)
        log_info("Cached wb_user for pending signup (email=#{email})")
      end

      result
    end

    private

    def log_info(message)
      Rails.logger.debug("[WB CMS] #{message}") if SiteSetting.oauth2_debug_auth
    end
  end

  if defined?(::OAuth2BasicAuthenticator)
    ::OAuth2BasicAuthenticator.prepend(::WbCmsAfterAuthenticateGroupSync)
  else
    Rails.logger.debug("[WB CMS] OAuth2BasicAuthenticator not found — cannot patch after_authenticate()") if SiteSetting.oauth2_debug_auth
  end

  on(:user_created) do |user|
    next unless SiteSetting.dm_WB_CMS_oauth2_group_sync_enabled

    email = user.email&.strip&.downcase
    wb_user = PluginStore.get(::DmWbCmsOauth2GroupSync::STORE_KEY, "pending_#{email}")
    next unless wb_user

    ::WbCmsGroupSync.sync_user(user, wb_user)
    PluginStore.remove(::DmWbCmsOauth2GroupSync::STORE_KEY, "pending_#{email}")

    Rails.logger.debug("[WB CMS] Applied cached wb_user after signup for #{user.username} (#{email})") if SiteSetting.oauth2_debug_auth
  end
end
