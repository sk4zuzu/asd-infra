# frozen_string_literal: true

require 'json'
require 'rspec'
require 'tmpdir'
require 'yaml'
require_relative 'microenv'

RSpec.describe 'combine' do
    it 'should merge recursively (no lists)' do
        a = {
            :a => { :s => 1 },
            :s => [ { :s => 2 } ]
        }
        s = {
            :a => { :s => 2 },
            :s => [ { :d => 3 }, { :f => 4 } ]
        }
        d = {
            :a => { :s => 2 },
            :s => [ { :d => 3 }, { :f => 4 } ]
        }
        expect(combine(a, s, :merge_lists => false)).to eq d
    end
    it 'should merge recursively' do
        a = {
            :a => { :s => 1 },
            :s => [ { :s => 2 } ],
            :d => [ { :f => 3 } ]
        }
        s = {
            :a => { :s => 2 },
            :s => [ { :d => 3 }, { :f => 4 } ],
            :d => []
        }
        d = {
            :a => { :s => 2 },
            :s => [ { :s => 2, :d => 3 }, { :f => 4 } ],
            :d => [ { :f => 3 } ]
        }
        expect(combine(a, s, :merge_lists => true)).to eq d
    end
end

RSpec.describe 'resolve_paths' do
    it 'should resolve paths (no flavors)' do
        stub_const 'MICROENV', 'kvm-asd'
        Dir.mktmpdir(['', '-kvm-asd']) do |dir| Dir.chdir(dir) do
            to_create = %w[
                ansible.cfg ansible.cfg#asd#1 ansible.cfg#omg
                bootstrap.yml bootstrap.yml#wth#1 bootstrap.yml#omg#2
                defaults.yml
                infra.yml
                inventory.yml inventory.yml#asd
                site.yml site.yml#asd site.yml#wth#2
            ].each { File.write(_1, '') }
            to_expect = {
                '' => %w[
                    ansible.cfg
                    bootstrap.yml
                    defaults.yml
                    infra.yml
                    inventory.yml
                    site.yml
                ].to_h { [_1.split(%[\#])[0], File.join(dir, _1)] }
            }
            expect(resolve_paths('')).to eq to_expect
        end
        end
    end
    it 'should resolve paths for asd+wth+omg (no federation)' do
        stub_const 'MICROENV', 'kvm-asd'
        Dir.mktmpdir(['', '-kvm-asd']) do |dir| Dir.chdir(dir) do
            to_create = %w[
                ansible.cfg ansible.cfg#asd ansible.cfg#omg
                infra.yml
                inventory.yml inventory.yml#asd
                site.yml site.yml#asd site.yml#wth
            ].each { File.write(_1, '') }
            to_expect = {
                '' => %w[
                    ansible.cfg#omg
                    infra.yml
                    inventory.yml#asd
                    site.yml#wth
                ].to_h { [_1.split(%[\#])[0], File.join(dir, _1)] }
            }
            expect(resolve_paths('asd+wth+omg')).to eq to_expect
        end
        end
    end
    it 'should resolve paths for asd+wth+omg (federation)' do
        stub_const 'MICROENV', 'kvm-asd'
        Dir.mktmpdir(['', '-kvm-asd']) do |dir| Dir.chdir(dir) do
            to_create = %w[
                ansible.cfg ansible.cfg#asd#1 ansible.cfg#omg#2
                infra.yml infra.yml#1
                inventory.yml inventory.yml#asd
                site.yml site.yml#asd site.yml#wth
            ].each { File.write(_1, '') }
            to_expect = {
                '' => %w[
                    ansible.cfg
                    infra.yml
                    inventory.yml#asd
                    site.yml#wth
                ].to_h { [_1.split(%[\#])[0], File.join(dir, _1)] },
                '1' => %w[
                    ansible.cfg#asd#1
                    infra.yml#1
                    inventory.yml#asd
                    site.yml#wth
                ].to_h { [_1.split(%[\#])[0], File.join(dir, _1)] },
                '2' => %w[
                    ansible.cfg#omg#2
                    infra.yml
                    inventory.yml#asd
                    site.yml#wth
                ].to_h { [_1.split(%[\#])[0], File.join(dir, _1)] }
            }
            expect(resolve_paths('asd+wth+omg')).to eq to_expect
        end
        end
    end
end

RSpec.describe 'build_inventory' do
    it 'should build inventory and match "ansible-inventory --list"' do
        inputs = [
            <<~YAML,
              ---
              all:
                vars: { a: 1 }
              a:
                vars: { s: 2 }
                children:
                  ? d
              s:
                vars: { d: 3, s: 0 }
                children:
                  ? d
                hosts:
                  x: { f: 4 }
              d:
                vars: { g: 5 }
                hosts:
                  y: { h: 6 }
            YAML
            <<~YAML,
            ---
            all:
              vars:
                ansible_user: root
            frontend:
              hosts:
                asd: { ansible_host: 10.11.12.13 }
            node:
              hosts:
                asd: { ansible_host: 10.11.12.13 }
            YAML
        ]
        Dir.mktmpdir do |dir|
            inputs.each do |yaml|
                File.write(p = File.join(dir, 'inventory.yml'), yaml)
                expect(build_inventory(YAML.load(yaml))).to eq (JSON.load(`ansible-inventory -i '#{p}' --list`))
            end
        end
    end
end
