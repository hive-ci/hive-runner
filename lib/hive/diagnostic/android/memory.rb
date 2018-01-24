# frozen_string_literal: true

require 'hive/diagnostic'
module Hive
  class Diagnostic
    class Android
      class Memory < Diagnostic
        def memory
          @memory ||= device_api.memory
          mem = @memory.mem_info
          { free: mem.free.split(' ').first,
            total: mem.total.split(' ').first,
            used: mem.used.split(' ').first }
        end

        def diagnose
          data = {}
          result = 'pass'
          operator = { free: :>=, used: :<=, total: :== }
          memory_status = memory
          config.each do |key, value|
            raise InvalidParameterError, "Battery Parameter should be any of ':free', ':used', ':total'" unless memory_status.key? key.to_sym
            data[:"#{key}_memory"] = { value: memory_status[:"#{key}"], unit: 'kB' }
            result = 'fail' unless memory_status[:"#{key}"].to_i.send(operator[:"#{key}"], value.to_i)
          end

          if result != 'pass'
            raise('Memory', data)
          else
            pass('Memory', data)
          end
        end

        def repair(_result)
          # Add repair for memory
          raise('Cannot repair memory')
        end
      end
    end
  end
end
