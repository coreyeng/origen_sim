require 'socket'
module OrigenSim
  # Responsible for managing and communicating with the simulator
  # process, a single instance of this class is instantiated as
  # OrigenSim.simulator
  class Simulator
    include Origen::PersistentCallbacks

    attr_reader :socket, :failed

    # Send the given message string to the simulator
    def put(msg)
      socket.write(msg + "\n") if socket
    end

    # Get a message from the simulator, will block until one
    # is received
    def get
      socket.readline
    end

    # This will be called at the end of every pattern, make
    # sure the simulator is not running behind before potentially
    # moving onto another pattern
    def pattern_generated(path)
      sync_up
    end

    # Called before every pattern is generated, but we only use it the
    # first time it is called to kick off the simulator process if the
    # current tester is an OrigenSim::Tester
    def before_pattern(name)
      if simulation_tester?
        unless @enabled
          @enabled = true
          # When running pattern back-to-back, only want to launch the simulator the
          # first time
          unless socket
            server = UNIXServer.new(socket_id)

            @sim_pid = spawn("rake sim:run[#{socket_id}]")
            Process.detach(@sim_pid)

            timeout_connection(5) do
              @socket = server.accept
              @connection_established = true
              if @connection_timed_out
                @failed_to_start = true
                Origen.log.error 'Simulator failed to respond'
                @failed = true
                exit
              end
            end
            data = get
            unless data.strip == 'READY!'
              @failed_to_start = true
              fail "The simulator didn't start properly!"
            end
            define_pins
            define_waves # TEMP, should be invoked by set_timeset
            # Apply the pin reset values before the simulation starts
            put_all_pin_states
          end
        end
      end
    end

    # Applies the current state of all pins to the simulation
    def put_all_pin_states
      dut.pins.each { |name, pin| pin.update_simulation }
    end
    
    # Tells the simulator about the pins in the current device so that it can
    # set up internal handles to efficiently access them
    def define_pins
      dut.pins.each_with_index do |(name, pin), i|
        pin.simulation_index = i
        if name == :tck
          put("0^#{pin.id}^#{i}^1^0") 
        else
          put("0^#{pin.id}^#{i}^0^0") 
        end
      end
    end

    def define_waves
      put('6^1^0^0_D_25_0_50_D_75_0') # Drive at 0ns, off at 25ns, drive at 50ns, off at 75ns
    end

    def end_simulation
      put('8^')
    end

    def set_period(period_in_ns)
      put("1^#{period_in_ns}")
    end

    def cycle(number_of_cycles)
      put("3^#{number_of_cycles}")
    end

    # Blocks the Origen process until the simulator indicates that it has
    # processed all operations up to this point
    def sync_up
      put('7^')
      data = get
      unless data.strip == 'OK!'
        fail 'Origen and the simulator are out of sync!'
      end
    end

    def on_origen_shutdown
      if @enabled
        Origen.log.info 'Shutting down simulator...'
        sync_up unless @failed_to_start
        end_simulation
        @socket.close if @socket
        File.unlink(socket_id) if File.exist?(socket_id)
        if failed
          Origen.app.stats.report_fail
        else
          Origen.app.stats.report_pass
        end
      end
    end

    def socket_id
      @socket_id ||= "/tmp/#{(Process.pid.to_s + Time.now.to_f.to_s).sub('.', '')}.sock"
    end

    def simulation_tester?
      (tester && tester.is_a?(OrigenSim::Tester))
    end

    def timeout_connection(wait_in_s)
      @connection_timed_out = false
      t = Thread.new do
        sleep wait_in_s
        # If the Verilog process has not established a connection yet, then make one to
        # release our process and then exit
        unless @connection_established
          @connection_timed_out = true
          UNIXSocket.new(socket_id).puts(message)
        end
      end
      yield
    end
  end
end
