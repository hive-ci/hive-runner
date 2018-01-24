# frozen_string_literal: true

module Hive
  class DiagnosticRunner
    attr_accessor :diagnostics, :options

    def initialize(options, diagnostics_config, platform, hive_mind = nil)
      @options     = options
      @platform    = platform
      @hive_mind   = hive_mind
      @diagnostics = initialize_diagnostics(diagnostics_config[@platform]) if diagnostics_config.key?(@platform)
    end

    def initialize_diagnostics(diagnostics_config)
      if diagnostics_config
        @diagnostics = diagnostics_config.collect do |component, config|
          Hive.logger.info("Initializing #{component.capitalize} component for #{@platform.capitalize} diagnostic")
          require "hive/diagnostic/#{@platform}/#{component}"
          Object.const_get('Hive').const_get('Diagnostic').const_get(@platform.capitalize).const_get(component.capitalize).new(config, @options, @hive_mind)
        end
      else
        Hive.logger.info("No diagnostic specified for #{@platform}")
      end
    end

    def run
      results = @diagnostics.collect(&:run)

      failures = results.select(&:failed?)
      failures.count == 0
    end
  end
end
