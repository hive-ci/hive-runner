require 'spec_helper'

# Using Hive::Device::Shell as a Hive::Device cannot be started on its own
require 'hive/device/shell'

describe Hive::Device do
  after(:each) do
    sleep 1
    `ps aux | grep TEST_WORKER | grep -v grep | awk '{ print $2 }'`.split("\n").each do |pid|
      Process.kill 'TERM', pid.to_i
    end
  end

  describe '#start' do
    it 'forks a test worker' do
      device = Hive::Device::Shell.new('id' => 1, 'name_stub' => 'TEST_WORKER')
      device.start
      sleep 1
      expect(`ps aux | grep TEST_WORKER | grep -v grep | wc -l`.to_i).to eq(1)
      # Clean up
      device.stop
    end
  end

  describe '#stop' do
    it 'terminates a test worker' do
      device = Hive::Device::Shell.new('id' => 1, 'name_stub' => 'TEST_WORKER')
      device.start
      sleep 1
      device.stop
      sleep 1
      expect(`ps aux | grep TEST_WORKER | grep -v grep | wc -l`.to_i).to eq(0)
    end
  end

  describe '#running?' do
    it 'shows that a worker is running' do
      device = Hive::Device::Shell.new('id' => 1, 'name_stub' => 'TEST_WORKER')
      device.start
      sleep 1
      expect(device.running?).to eq(true)
      # Clean up
      device.stop
    end

    it 'shows that a worker is not running' do
      device = Hive::Device::Shell.new('id' => 1, 'name_stub' => 'TEST_WORKER')
      device.start
      sleep 1
      device.stop
      sleep 1
      expect(device.running?).to eq(false)
    end
  end
end
