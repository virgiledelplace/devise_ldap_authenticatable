require "net/ldap"

module Devise
  module LdapAdapter
    DEFAULT_GROUP_UNIQUE_MEMBER_LIST_KEY = 'uniqueMember'

    def self.valid_credentials?(login, password_plaintext , fallback)

      options = {:login => login,
                 :password => password_plaintext,
                 :ldap_auth_username_builder => ::Devise.ldap_auth_username_builder,
                 :admin => ::Devise.ldap_use_admin_to_bind}


      resource = LdapConnect.new(options)
      resource.authorized?
    end

    def self.update_password(login, new_password)
      options = {:login => login,
                 :new_password => new_password,
                 :ldap_auth_username_builder => ::Devise.ldap_auth_username_builder,
                 :admin => ::Devise.ldap_use_admin_to_bind}

      resource = LdapConnect.new(options)
      resource.change_password! if new_password.present?
    end

    def self.update_own_password(login, new_password, current_password)
      set_ldap_param(login, :userpassword, new_password, current_password)
    end

    def self.ldap_connect(login)
      options = {:login => login,
                 :ldap_auth_username_builder => ::Devise.ldap_auth_username_builder,
                 :admin => ::Devise.ldap_use_admin_to_bind}

      resource = LdapConnect.new(options)
    end

    def self.group_exists?(login, dn)
      self.ldap_connect(login).group_exists?(dn)
    end

    def self.valid_login?(login)
      self.ldap_connect(login).valid_login?
    end

    def self.get_groups(login)
      self.ldap_connect(login).user_groups
    end

    def self.in_ldap_group?(login, group_name, group_attribute = nil)
      self.ldap_connect(login).in_group?(group_name, group_attribute)
    end

    def self.get_dn(login)
      self.ldap_connect(login).dn
    end

    def self.set_ldap_param(login, param, new_value, password = nil)
      options = { :login => login,
                  :ldap_auth_username_builder => ::Devise.ldap_auth_username_builder,
                  :password => password }

      resource = LdapConnect.new(options)
      resource.set_param(param, new_value , login)
    end

    def self.delete_ldap_param(login, param, password = nil)
      options = { :login => login,
                  :ldap_auth_username_builder => ::Devise.ldap_auth_usernamer_builder,
                  :password => password }

      resource = LdapConnect.new(options)
      resource.delete_param(param)
    end

    def self.get_ldap_param(login,param)
      resource = self.ldap_connect(login)
      resource.ldap_param_value(param)
    end

    def self.get_ldap_entry(login)
      self.ldap_connect(login).search_for_login
    end

    def self.add_entry(login , param)
      self.ldap_connect(login).add_entry(param)
    end

    def self.delete_entry(login , param)
      self.ldap_connect(login).delete_entry(param)
    end

    def self.add_group_entry(login , param)
      self.ldap_connect(login).add_group_entry(param)
    end

    def self.delete_group_entry(login , param)
      self.ldap_connect(login).delete_group_entry(param)
    end

    def self.add_attribute_to_group(login , param)
      self.ldap_connect(login).add_attribute_to_group(param)
    end


    class LdapConnect

      attr_reader :ldap, :login

      def initialize(params = {})
        ldap_config = (YAML.load(ERB.new(File.read(::Devise.ldap_config || "#{Rails.root}/config/ldap.yml")).result).has_key? "default") ? YAML.load(ERB.new(File.read(::Devise.ldap_config || "#{Rails.root}/config/ldap.yml")).result)["default"] : YAML.load(ERB.new(File.read(::Devise.ldap_config || "#{Rails.root}/config/ldap.yml")).result)[Rails.env]
        ldap_options = params
        ldap_config["ssl"] = :simple_tls if ldap_config["ssl"] === true
        ldap_options[:encryption] = ldap_config["ssl"].to_sym if ldap_config["ssl"]

        @ldap = Net::LDAP.new(ldap_options)
        @ldap.host  =                 ldap_config["host"]
        @ldap.port  =                 ldap_config["port"]
        @ldap.base  =                 ldap_config["base"]
        @ldap.encryption(method: :simple_tls, :tls_options => {:verify_mode => 0}) if ldap_config["ssl_verify_mode"] == false
        @people_base =                ldap_config["people_base"]
        @groups_base =                ldap_config["groups_base"]  
        @attribute  =                 ldap_config["attribute"]
        @attributes =                 ldap_config["attributes"].flatten
        @ldap_auth_username_builder = params[:ldap_auth_username_builder]

        @group_base = ldap_config["group_base"]
        @check_group_membership = ldap_config.has_key?("check_group_membership") ? ldap_config["check_group_membership"] : ::Devise.ldap_check_group_membership
        @required_groups = ldap_config["required_groups"]
        @required_attributes = ldap_config["require_attribute"]

        @ldap.auth ldap_config["admin_user"], ldap_config["admin_password"] if params[:admin]

        @login = params[:login]
        @password = params[:password]
        @new_password = params[:new_password]
      end

      def delete_param(param)
        update_ldap [[:delete, param.to_sym, nil]]
      end

      def set_param(param, new_value , login)
        update_ldap( { param.to_sym => new_value }, login )
      end

      def dn
        DeviseLdapAuthenticatable::Logger.send("LDAP dn lookup: #{@attribute}=#{@login}")
        ldap_entry = search_for_login
        if ldap_entry.nil?
          @ldap_auth_username_builder.call(@attribute,@login,@ldap)
        else
          ldap_entry.dn
        end
      end

      def ldap_param_value(param)
        filter = Net::LDAP::Filter.eq(@attribute.to_s, @login.to_s)
        ldap_entry = nil
        if @attributes
          @ldap.search(:filter => filter, :attributes => @attributes) {|entry| ldap_entry = entry}
        else
          @ldap.search(:filter => filter) {|entry| ldap_entry = entry}
        end

        if ldap_entry
          if ldap_entry[param]
            DeviseLdapAuthenticatable::Logger.send("Requested param #{param} has value #{ldap_entry.send(param)}")
            value = ldap_entry.send(param)
            value = value.first if value.is_a?(Array) and value.count == 1
            value
          else
            DeviseLdapAuthenticatable::Logger.send("Requested param #{param} does not exist")
            value = nil
          end
        else
          DeviseLdapAuthenticatable::Logger.send("Requested ldap entry does not exist")
          value = nil
        end
      end

      def authenticate!
        @ldap.auth(dn, @password)
        @ldap.bind
      end

      def authenticated?
        authenticate!
      end

      def authorized?
        DeviseLdapAuthenticatable::Logger.send("Authorizing user #{dn}")
        authenticated? && in_required_groups? && has_required_attribute?
      end

      def change_password!
        update_ldap(:userpassword => Net::LDAP::Password.generate(:sha, @new_password))
      end

      def in_required_groups?
        return true unless @check_group_membership

        ## FIXME set errors here, the ldap.yml isn't set properly.
        return false if @required_groups.nil?

        for group in @required_groups
          unless in_group?(*group)
            return false
          end
        end
        return true
      end

      def in_group?(group_name, group_attribute = DEFAULT_GROUP_UNIQUE_MEMBER_LIST_KEY)
        admin_ldap = LdapConnect.admin

        unless ::Devise.ldap_ad_group_check
          admin_ldap.search(:base => group_name, :scope => Net::LDAP::SearchScope_BaseObject) do |entry|
            unless entry[group_attribute].include? dn
              DeviseLdapAuthenticatable::Logger.send("User #{dn} is not in group: #{group_name }")
              return false
            end
          end
        else
          # AD optimization - extension will recursively check sub-groups with one query
          # "(memberof:1.2.840.113556.1.4.1941:=group_name)"
          search_result = admin_ldap.search(:base => dn,
                            :filter => Net::LDAP::Filter.ex("memberof:1.2.840.113556.1.4.1941", group_name),
                            :scope => Net::LDAP::SearchScope_BaseObject)
          # Will return  the user entry if belongs to group otherwise nothing
          unless search_result.length == 1 && search_result[0].dn.eql?(dn)
            DeviseLdapAuthenticatable::Logger.send("User #{dn} is not in group: #{group_name }")
            return false
          end
        end

        return true
      end

      def has_required_attribute?
        return true unless ::Devise.ldap_check_attributes

        admin_ldap = LdapConnect.admin

        user = find_ldap_user(admin_ldap)

        @required_attributes.each do |key,val|
          unless user[key].include? val
            DeviseLdapAuthenticatable::Logger.send("User #{dn} did not match attribute #{key}:#{val}")
            return false
          end
        end

        return true
      end

      def user_groups
        admin_ldap = LdapConnect.admin

        DeviseLdapAuthenticatable::Logger.send("Getting groups for #{dn}")
        filter = Net::LDAP::Filter.eq("uniqueMember", dn)
        admin_ldap.search(:filter => filter, :base => @group_base).collect(&:dn)
      end

      def valid_login?
        !search_for_login.nil?
      end

      # Searches the LDAP for the login
      #
      # @return [Object] the LDAP entry found; nil if not found
      def search_for_login
        DeviseLdapAuthenticatable::Logger.send("LDAP search for login: #{@attribute}=#{@login}")
        filter = Net::LDAP::Filter.eq(@attribute.to_s, @login.to_s)
        ldap_entry = nil
        @ldap.search(:filter => filter) {|entry| ldap_entry = entry}
        ldap_entry
      end

      def add_entry param
        DeviseLdapAuthenticatable::Logger.send("LDAP add dn: #{param[:dn]}")
        @ldap.add(dn: "#{create_dn param[:dn]}", attributes: param[:attributes])
      end

      def add_group_entry param
        DeviseLdapAuthenticatable::Logger.send("LDAP add group dn: #{param[:dn]}")
        (param[:attributes][:uniqueMember] = create_dn param[:attributes][:uniqueMember] ) if param[:attributes][:uniqueMember].present?
        @ldap.add(dn: "#{create_group_dn param[:dn]}", attributes: param[:attributes])
      end

       def delete_entry param
        DeviseLdapAuthenticatable::Logger.send("LDAP search group of uid : #{param[:dn]}")
        groups = ldap_param_value('memberof')
        dn = create_dn param[:dn]

        groups.split.each do |group|
          group_cn = group.split(',').first.split('=').last
          DeviseLdapAuthenticatable::Logger.send("LDAP delete from group : #{group} dn: #{dn}")
          filter = Net::LDAP::Filter.eq("objectClass", "groupOfUniqueNames") & Net::LDAP::Filter.eq("cn", group_cn)
          members = @ldap.search(:filter => filter, :attributes => ['uniqueMember'])
          members.first[:uniqueMember].delete(dn)
          if members.first[:uniqueMember].count > 0
            DeviseLdapAuthenticatable::Logger.send("LDAP group:  #{group} new value #{members.first[:uniqueMember]}")
            @ldap.replace_attribute("#{group}", :uniqueMember, members.first[:uniqueMember])
          else
            param = { dn: group_cn }
            delete_group_entry param
          end
        end
        DeviseLdapAuthenticatable::Logger.send("LDAP delete dn: #{param[:dn]}")
        @ldap.delete(dn: "#{dn}")
      end


      def delete_group_entry param
        DeviseLdapAuthenticatable::Logger.send("LDAP delete group dn: #{param[:dn]}")
        @ldap.delete(dn: "#{create_group_dn param[:dn]}")
      end

      def add_attribute_to_group param
        DeviseLdapAuthenticatable::Logger.send("LDAP add attribute #{param[:attribute]} value #{create_dn param[:value]} to group dn: #{create_group_dn param[:dn]}")
        @ldap.add_attribute("#{create_group_dn param[:dn]}", "#{param[:attribute]}", "#{create_dn param[:value]}")
      end

      def create_dn login
         "cn=#{login},#{@people_base}"
      end

      def create_group_dn login
         "cn=#{login},#{@groups_base}"
      end

      def group_exists? dn
        filter = Net::LDAP::Filter.eq("objectClass", "groupOfUniqueNames") & Net::LDAP::Filter.eq("cn", dn)
        ldap_entry = nil
        @ldap.search(:filter => filter) {|entry| ldap_entry = entry}
        ldap_entry
      end

      private

      def self.admin
        ldap = LdapConnect.new(:admin => true).ldap

        unless ldap.bind
          DeviseLdapAuthenticatable::Logger.send("Cannot bind to admin LDAP user")
          raise DeviseLdapAuthenticatable::LdapException, "Cannot connect to admin LDAP user"
        end

        return ldap
      end

      def find_ldap_user(ldap)
        DeviseLdapAuthenticatable::Logger.send("Finding user: #{dn}")
        ldap.search(:base => dn, :scope => Net::LDAP::SearchScope_BaseObject).try(:first)
      end

      def update_ldap(ops, login = nil)
        operations = []
        if ops.is_a? Hash
          ops.each do |key,value|
            operations << [:replace,key,value]
          end
        elsif ops.is_a? Array
          operations = ops
        end

        if ::Devise.ldap_use_admin_to_bind
          privileged_ldap = LdapConnect.admin
        else
          authenticate!
          privileged_ldap = self.ldap
        end

        DeviseLdapAuthenticatable::Logger.send("Modifying user #{create_dn(login)}")
        privileged_ldap.modify(:dn => create_dn(login), :operations => operations)
      end

    end

  end

end
