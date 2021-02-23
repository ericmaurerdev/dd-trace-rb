require 'ffi'

module Datadog
  module Profiling
    module Ext
      # C-struct for retrieving clock ID from pthread
      if RUBY_PLATFORM =~ /darwin/
        MACOS_INTEGER_T = :int      # https://github.com/apple/darwin-xnu/blob/main/osfmk/mach/i386/vm_types.h#L93
        MACOS_POLICY_T = :int       # https://github.com/apple/darwin-xnu/blob/main/osfmk/mach/policy.h#L79
      
        class StructTimeValue < FFI::Struct
          layout(
            seconds: MACOS_INTEGER_T,
            microseconds: MACOS_INTEGER_T,
          )
        end
      
        class MachMsgTypeNumberT < FFI::Struct
          layout(
            fixme: :uint,
          )
        end
      
        MACOS_TIME_VALUE_T = StructTimeValue
      
        class StructThreadBasicInfo < FFI::Struct
          # https://github.com/apple/darwin-xnu/blob/main/osfmk/mach/thread_info.h#L92
          layout(
            user_time:     MACOS_TIME_VALUE_T,
            system_time:   MACOS_TIME_VALUE_T,
            cpu_usage:     MACOS_INTEGER_T,
            policy:        MACOS_POLICY_T,
            run_state:     MACOS_INTEGER_T,
            flags:         MACOS_INTEGER_T,
            suspend_count: MACOS_INTEGER_T,
            sleep_time:    MACOS_INTEGER_T,
          )
        end

        THREAD_BASIC_INFO = 3 # https://github.com/apple/darwin-xnu/blob/main/osfmk/mach/thread_info.h#L90
        THREAD_BASIC_INFO_COUNT = StructThreadBasicInfo.size / FFI::TypeDefs[:uint].size
      elsif RUBY_PLATFORM =~ /linux/
        class CClockId < FFI::Struct
          layout :value, :int
        end  
      end

      # Extension used to enable CPU-time profiling via use of Pthread's `getcpuclockid`.
      module CThread
        extend FFI::Library
        ffi_lib FFI::CURRENT_PROCESS
        attach_function :pthread_self, [], :ulong
        if RUBY_PLATFORM =~ /darwin/
          attach_function(
            :mach_thread_self, # http://web.mit.edu/darwin/src/modules/xnu/osfmk/man/mach_thread_self.html
                               # https://github.com/apple/darwin-xnu/blob/8f02f2a044b9bb1ad951987ef5bab20ec9486310/libsyscall/mach/mach/mach_init.h#L73
            [],                # no args
            :uint,             # mach_port_t => __darwin_mach_port_t => __darwin_mach_port_name_t => __darwin_natural_t => unsigned int
          )
          attach_function(
            :thread_info,      # https://github.com/apple/darwin-xnu/blob/main/osfmk/mach/thread_act.defs#L241
                               # https://developer.apple.com/documentation/kernel/1418630-thread_info
            [
              :uint,           # thread_inspect_it => mach_port_t => (see above)
              :uint,           # thread_flavor_t => natural_t => __darwin_natural_t => (see above)
              StructThreadBasicInfo.by_ref,
              MachMsgTypeNumberT.by_ref,         # mach_msg_type_number_t *thread_info_outCnt
            ],
            :int,              # kern_return_t
          )
        elsif RUBY_PLATFORM =~ /linux/
          attach_function :pthread_getcpuclockid, [:ulong, CClockId], :int
        end

        def self.prepended(base)
          # Threads that have already been created, will not have resolved
          # a thread/clock ID. This is because these IDs can only be resolved
          # from within the thread's execution context, which we do not control.
          #
          # We can mitigate this for the current thread via #update_native_ids,
          # since we are currently running within its execution context. We cannot
          # do this for any other threads that may have been created already.
          # (This is why it's important that CThread is applied before anything else runs.)
          base.current.send(:update_native_ids) if base.current.is_a?(CThread)
        end

        attr_reader \
          :native_thread_id

        def initialize(*args)
          @pid = ::Process.pid
          @native_thread_id = nil
          if RUBY_PLATFORM =~ /darwin/
            @thread_port = mach_thread_self()  # TODO: This needs to be released!
          elsif RUBY_PLATFORM =~ /linux/
            @clock_id = nil
          end

          # Wrap the work block with our own
          # so we can retrieve the native thread ID within the thread's context.
          wrapped_block = proc do |*t_args|
            # Set native thread ID & clock ID
            update_native_ids
            yield(*t_args)
          end
          wrapped_block.ruby2_keywords if wrapped_block.respond_to?(:ruby2_keywords, true)

          super(*args, &wrapped_block)
        end
        ruby2_keywords :initialize if respond_to?(:ruby2_keywords, true)

        def clock_id
          update_native_ids if forked?
          defined?(@clock_id) && @clock_id
        end

        def thread_port
          update_native_ids if forked?
          defined?(@thread_port) && @thread_port
        end
        
        def cpu_time(unit = :float_second)
          return unless clock_id && ::Process.respond_to?(:clock_gettime)
          begin
            if RUBY_PLATFORM =~ /darwin/
              thread_basic_info = StructThreadBasicInfo.new
              thread_info_out_cnt = MachMsgTypeNumberT.new
              thread_info_out_cnt[:fixme] = THREAD_BASIC_INFO_COUNT
              thread_info_result = thread_info(thread_port, THREAD_BASIC_INFO, thread_basic_info, thread_info_out_cnt)
              thread_basic_info[:cpu_usage]
            elsif RUBY_PLATFORM =~ /linux/
              ::Process.clock_gettime(clock_id, unit)
            end
          rescue ::Errno::EINVAL
            puts "Failed to get clock_id for thread #{Thread.current} clock_id #{clock_id}"
            nil # ¯\_(ツ)_/¯
          end
        end

        def cpu_time_instrumentation_installed?
          # If this thread was started before this module was added to Thread OR if something caused the initialize
          # method above not to be properly called on new threads, this instance variable is never defined (never set to
          # any value at all, including nil).
          #
          # Thus, we can use @clock_id as a canary to detect a thread that has missing instrumentation, because we
          # know that in initialize above we always set this variable to nil.
          defined?(@clock_id) != nil
        end

        private

        # Retrieves number of classes from runtime
        def forked?
          ::Process.pid != (@pid ||= nil)
        end

        def update_native_ids
          # Can only resolve if invoked from same thread.
          return unless ::Thread.current == self

          @pid = ::Process.pid
          @native_thread_id = get_native_thread_id
          if RUBY_PLATFORM =~ /darwin/
            @thread_port = mach_thread_self()
          elsif RUBY_PLATFORM =~ /linux/
            @clock_id = get_clock_id(@native_thread_id)
          end
        end

        def get_native_thread_id
          # Only run if invoked from same thread, otherwise
          # it will receive incorrect thread ID.
          return unless ::Thread.current == self

          # NOTE: Only returns thread ID for thread that evaluates this call.
          #       a.k.a. evaluating `thread_a.get_native_thread_id` from within
          #       `thread_b` will return `thread_b`'s thread ID, not `thread_a`'s.
          pthread_self
        end

        def get_clock_id(pthread_id)
          return unless pthread_id && alive?

          # Build a struct, pass it to Pthread's getcpuclockid function.
          clock = CClockId.new
          clock[:value] = 0
          pthread_getcpuclockid(pthread_id, clock).zero? ? clock[:value] : nil
        end
      end

      # Threads in Ruby can be started by creating a new instance of `Thread` (or a subclass) OR by calling
      # `start`/`fork` on `Thread` (or a subclass).
      #
      # This module intercepts calls to `start`/`fork`, ensuring that the `update_native_ids` operation is correctly
      # called once the new thread starts.
      #
      # Note that unlike CThread above, this module should be prepended to the `Thread`'s singleton class, not to
      # the class.
      module WrapThreadStartFork
        def start(*args)
          # Wrap the work block with our own
          # so we can retrieve the native thread ID within the thread's context.
          wrapped_block = proc do |*t_args|
            # Set native thread ID & clock ID
            ::Thread.current.send(:update_native_ids)
            yield(*t_args)
          end

          super(*args, &wrapped_block)
        end

        alias fork start
      end
    end
  end
end
