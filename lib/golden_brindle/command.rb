module GoldenBrindle
  
  
  def GoldenBrindle::send_signal(signal, pid_file)
    pid = open(pid_file).read.to_i
    print "Sending #{signal} to Unicorn at PID #{pid}..."
    begin
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      puts "Process does not exist.  Not running."
    end
    puts "Done."
  end
  
  module Command
    
    module Base
      
      attr_reader :valid, :done_validating, :original_args

      # Called by the implemented command to set the options for that command.
      # Every option has a short and long version, a description, a variable to
      # set, and a default value.  No exceptions.
      def options(opts)
        # process the given options array
        opts.each do |short, long, help, variable, default|
          self.instance_variable_set(variable, default)
          @opt.on(short, long, help) do |arg|
            self.instance_variable_set(variable, arg)
          end
        end
      end
      
      
      # Called by the subclass to setup the command and parse the argv arguments.
      # The call is destructive on argv since it uses the OptionParser#parse! function.
      def initialize(options={})
        argv = options[:argv] || []
        @opt = OptionParser.new
        @opt.banner = GoldenBrindle::Const::BANNER
        @valid = true
        # this is retarded, but it has to be done this way because -h and -v exit
        @done_validating = false
        @original_args = argv.dup

        configure

        # I need to add my own -h definition to prevent the -h by default from exiting.
        @opt.on_tail("-h", "--help", "Show this message") do
          @done_validating = true
          puts @opt
        end

        # I need to add my own -v definition to prevent the -v from exiting by default as well.
        @opt.on_tail("--version", "Show version") do
          @done_validating = true
          if VERSION
            puts "Version #{GoldenBrindle::Const::VERSION}"
          end
        end

        @opt.parse! argv
      end

      def configure
        options []
      end
      
      def config_keys
        @config_keys ||=
          %w(address host port cwd log_file pid_file environment servers daemon debug config_script num_workers timeout user group prefix preload listen)
      end
      
      def load_config
        settings = {}
        begin
          settings = YAML.load_file(@config_file)
        ensure
          STDERR.puts "** Loading settings from #{@config_file} (they override command line)." unless @daemon || settings[:daemon] 
        end

        # Config file settings will override command line settings
        settings.each do |key, value|
          key = key.to_s
          if config_keys.include?(key)
            key = 'address' if key == 'host'
            self.instance_variable_set("@#{key}", value)
          else
            failure "Unknown configuration setting: #{key}"  
            @valid = false
          end
        end
      end

      # Returns true/false depending on whether the command is configured properly.
      def validate
        return @valid
      end

      # Returns a help message.  Defaults to OptionParser#help which should be good.
      def help
        @opt.help
      end

      # Runs the command doing it's job.  You should implement this otherwise it will
      # throw a NotImplementedError as a reminder.
      def run
        raise NotImplementedError
      end


      # Validates the given expression is true and prints the message if not, exiting.
      def valid?(exp, message)
        if not @done_validating and (not exp)
          failure message
          @valid = false
          @done_validating = true
        end
      end

      # Validates that a file exists and if not displays the message
      def valid_exists?(file, message)
        valid?(file != nil && File.exist?(file), message)
      end


      # Validates that the file is a file and not a directory or something else.
      def valid_file?(file, message)
        valid?(file != nil && File.file?(file), message)
      end

      # Validates that the given directory exists
      def valid_dir?(file, message)
        valid?(file != nil && File.directory?(file), message)
      end

      def valid_user?(user)
        valid?(@group, "You must also specify a group.")
        begin
          Etc.getpwnam(user)
        rescue
          failure "User does not exist: #{user}"
          @valid = false
        end
      end

      def valid_group?(group)
        valid?(@user, "You must also specify a user.")
        begin
          Etc.getgrnam(group)
        rescue
          failure "Group does not exist: #{group}"
          @valid = false
        end
      end

      # Just a simple method to display failure until something better is developed.
      def failure(message)
        STDERR.puts "!!! #{message}"
      end
      
    end
    
    # A Singleton class that manages all of the available commands
    # and handles running them.
    class Registry
      include Singleton

      # Builds a list of possible commands from the Command derivates list
      def commands
        pmgr = GemPlugin::Manager.instance
        list = pmgr.plugins["/commands"].keys
        return list.sort
      end

      # Prints a list of available commands.
      def print_command_list
        puts "#{GoldenBrindle::Const::BANNER}\nAvailable commands are:\n\n"

        self.commands.each do |name|
          if /brindle::/ =~ name
            name = name[9 .. -1]
          end

          puts " - #{name[1 .. -1]}\n"
        end

        puts "\nEach command takes -h as an option to get help."

      end


      # Runs the args against the first argument as the command name.
      # If it has any errors it returns a false, otherwise it return true.
      def run(args)
        # find the command
        cmd_name = args.shift

        if !cmd_name or cmd_name == "?" or cmd_name == "help"
          print_command_list
          return true
        elsif cmd_name == "--version"
          puts "Golden Brindle #{GoldenBrindle::Const::VERSION}"
          return true
        end

        begin
          if ["start", "stop", "restart", "configure", "reload"].include? cmd_name
            cmd_name = "brindle::" + cmd_name
          end
          command = GemPlugin::Manager.instance.create("/commands/#{cmd_name}", :argv => args)
        rescue OptionParser::InvalidOption
          STDERR.puts "#$! for command '#{cmd_name}'"
          STDERR.puts "Try #{cmd_name} -h to get help."
          return false
        rescue
          STDERR.puts "ERROR RUNNING '#{cmd_name}': #$!"
          STDERR.puts "Use help command to get help"
          return false
        end

        # Normally the command is NOT valid right after being created
        # but sometimes (like with -h or -v) there's no further processing
        # needed so the command is already valid so we can skip it.
        if not command.done_validating
          if not command.validate
            STDERR.puts "#{cmd_name} reported an error. Use goldent_brindle #{cmd_name} -h to get help."
            return false
          else
            command.run
          end
        end

        return true
      end
    end
    
  end
  
end