#
# Copyright (c) 2012 Sean Laurent
#
module EC2Launcher
	# Helper module for all objects that support EC2 Security Groups.
	module SecurityGroupHandler

		# Add or retrieve security groups. Defines the @security_groups instance variable,
		# which contains a Hash of environment names to Arrays of security group names.
		# May define a "default" environment.
		# 
		# Can be defined several different ways:
		#   * String - Adds the named security group to the "default" environment.
		#   * Array - Adds the entire array of security groups to the "default" environment.
		#   * Hash - Keys are environment names (Strings) to security groups. Values of the
		#            hash can be either a String or an Array. Both are appended to any
		#            security groups already defined for the environment.
		#
		# @param [Array, nil] groups  Array of security_group definitions. See above. Returns
		#                             the entire Hash of security groups if empty.
		#
		# @return [Hash, self] Either returns the Hash of security groups (if groups parameter is empty)
		#                      or returns a reference to self.
		def security_groups(*groups)
			if groups.empty?
				@security_groups
			else
				@security_groups = Hash.new if @security_groups.nil?
				if groups[0].kind_of? Array
					@security_groups["default"] = [] if @security_groups["default"].nil?
					@security_groups["default"] += groups[0]
				elsif groups[0].kind_of? Hash
					groups[0].keys.each do |env_name|
						@security_groups[env_name] = [] if @security_groups[env_name].nil?
						if groups[0][env_name].kind_of? Array
							@security_groups[env_name] += groups[0][env_name]
						else
							@security_groups[env_name] << groups[0][env_name]
						end
					end
				else
					@security_groups["default"] = [] if @security_groups["default"].nil?
					@security_groups["default"] << groups[0].to_s
				end
				self
			end
		end
	end
end