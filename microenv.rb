#!/usr/bin/env ruby

require 'optparse'
require 'erb'
require 'json'
require 'yaml'
require 'opennebula'

ONE_XMLRPC = 'http://10.2.11.40:2633/RPC2'
ONE_AUTH   = 'oneadmin:asd'

TEMPLATE     = 'ubuntu2404'
MICROENV     = 'kvm-ssh'
VERSION      = '7.0'
ID           = 'asd12'
DOMAIN       = 'test'
STEM         = "#{TEMPLATE}-#{MICROENV}-#{VERSION.gsub(%[\.], %[\-])}-#{ID}"
VM_STEM      = STEM
VNET_STEM    = "private-#{STEM}"
VMGROUP_STEM = STEM

def combine(*args, merge_lists: false)
    recurse = proc { |a, b|
        case
        when a.is_a?(Hash) && b.is_a?(Hash)
            a.merge(b) { |_, a, b| recurse.call(a, b) }
        when merge_lists && a.is_a?(Array) && b.is_a?(Array)
            0.upto([a.length, b.length].max - 1).each_with_object([]) do |i, acc|
                [a, b].each_with_object([]) do |v, ab|
                    ab << v.fetch(i)
                rescue IndexError
                end.then do |ab|
                    acc << ((ab.length == 2) ? recurse.call(*ab) : ab[0])
                end
            end
        else
            b
        end
    }
    ab = []
    while !(a = args.shift).nil?
        next if (ab << a).length < 2
        ab.replace [recurse.call(*ab)]
    end
    ab.first
end

def to_one(h)
    (recurse = proc { |h|
        h.each_with_object([]) do |(k, vv), acc|
            case
            when vv.is_a?(Hash)
                acc << %[#{k}=[#{recurse.call(vv).join(%[\,])}]]
            when vv.is_a?(Array)
                vv.each { |v| acc << %[#{k}=[#{recurse.call(v).join(%[\,])}]] }
            when vv.is_a?(String)
                acc << %[#{k}="#{vv.gsub(%[\"], %[\\\"])}"]
            else
                acc << %[#{k}="#{vv}"]
            end
        end
    }).call(h).join(%[\n])
end

def parse_extra_yml(b)
    case
    when File.exist?(path = "./#{MICROENV}/extra.yml")
    when File.exist?(path = "./extra.yml")
    else raise
    end
    YAML.load ERB.new(File.read(path), :trim_mode => %[\-]).result(b)
end

def ensure_vnets(one, extra_yml)
    rc = (pool = OpenNebula::VirtualNetworkPool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    extra_yml['vnets'].each do |it|
        next if pool.find { |f| f.name == it.dig('template', 'NAME') }
        x = OpenNebula::VirtualNetwork.new OpenNebula::VirtualNetwork.build_xml, one
        rc = x.allocate to_one(it.dig('template')), -1
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def ensure_vmgroup(one, extra_yml)
    rc = (pool = OpenNebula::VMGroupPool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    unless pool.find { |f| f.name == VMGROUP_STEM }
        x = OpenNebula::VMGroup.new OpenNebula::VMGroup.build_xml, one
        rc = x.allocate to_one({
            'NAME' => VMGROUP_STEM,
            'ROLE' => { 'NAME' => 'undefined', 'POLICY' => 'AFFINED' }
        })
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def ensure_templates(one, extra_yml)
    rc = (pool = OpenNebula::TemplatePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    exit(-1) unless (b = pool.find { |f| f.name == TEMPLATE })
    extra_yml['vms'].each do |it|
        next if pool.find { |f| f.name == it.dig('template', 'NAME') }
        id = b.clone it.dig('template', 'NAME'), true
        pp(id).then{exit(-1)} if OpenNebula.is_error?(id)
        x = OpenNebula::Template.new OpenNebula::Template.build_xml(id), one
        rc = x.info
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
        update = combine x.to_hash.dig('VMTEMPLATE', 'TEMPLATE'),
                         it.dig('template'),
                         { 'VMGROUP' => { 'VMGROUP_NAME' => VMGROUP_STEM, 'ROLE' => 'undefined' } },
                         merge_lists: true
        rc = x.update to_one(update), 0
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def ensure_vms(one, extra_yml)
    rc = (pool1 = OpenNebula::VirtualMachinePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    rc = (pool2 = OpenNebula::TemplatePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    extra_yml['vms'].each do |it|
        next if pool1.find { |f| f.name == it.dig('template', 'NAME') }
        exit(-1) unless (x = pool2.find { |f| f.name == it.dig('template', 'NAME') })
        rc = x.instantiate it.dig('template', 'NAME')
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def extract_groups(inventory_yml)
    inventory_yml.each_with_object({}) do |(g, v), acc|
        acc[g] ||= {}
        acc[g]['hosts']    = v['hosts'].keys unless v['hosts'].nil?
        acc[g]['children'] = v['children']   unless v['children'].nil?
    end.then do |groups|
        all_hosts = groups.each_with_object([]) do |(_, v), acc|
            next if v['hosts'].nil?
            acc << v['hosts']
        end.flatten.uniq
        combine groups, {
            'all' => {
                'children' => ['ungrouped'] + groups.keys - ['all'],
                'hosts'    => all_hosts
            }
        }
    end
end

def extract_hostvars(inventory_yml)
    (recurse = proc { |node, vars, acc|
        node&.dig('children').to_a.each do |g|
            m = combine vars.to_h,
                        node&.dig('vars').to_h
            recurse.call inventory_yml[g], m, acc
        end
        node&.dig('hosts').to_a.each do |h, v|
            m = combine vars.to_h,
                        (acc[h] ||= {}),
                        node&.dig('vars').to_h,
                        v.to_h
            acc[h].replace m
        end
    }).call inventory_yml['all'], {}, (hostvars = {})
    hostvars
end

def build_inventory(inventory_yml)
    groups = extract_groups(inventory_yml)

    inventory_yml['all']['children'] = groups['all']['children']

    hostvars = extract_hostvars(inventory_yml)

    combine ({ '_meta' => { 'hostvars' => hostvars } }), groups
end

def parse_inventory_yml(b)
    case
    when File.exist?(path = "./#{MICROENV}/inventory.yml")
    when File.exist?(path = "./inventory.yml")
    else raise
    end
    YAML.load ERB.new(File.read(path), :trim_mode => %[\-]).result(b)
end

def render_inventory(one, extra_yml)
    rc = (pool = OpenNebula::VirtualMachinePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    extra_yml['vms'].each_with_object([]) do |it, acc|
        next unless (vm = pool.find { |f| f.name == it.dig('template', 'NAME') })
        h = vm.to_hash['VM']
        acc << {
            'inventory_hostname' => h.dig('NAME'),
            'ansible_host'       => h.dig('TEMPLATE', 'NIC', 0, 'IP')
        }
    end.then do |vms|
        inventory_yml = parse_inventory_yml(binding)
        JSON.dump(build_inventory(inventory_yml))
    end
end

def run_ansible
    Dir.chdir "./#{MICROENV}/"
    exec 'ansible-playbook', '-v', 'site.yml'
end

if caller.empty?
    options = {}
    OptionParser.new do |opt|
        opt.on('--host HOSTNAME') { raise NotImplementedError }
        opt.on('--apply')         { options[:apply] = true }
        opt.on('--list')          { options[:list] = true }
    end.parse!

    args = OpenNebula::Client.new(ONE_AUTH, ONE_XMLRPC, :sync => true), parse_extra_yml(binding)

    case
    when options[:apply]
        ensure_vnets(*args)
        ensure_vmgroup(*args)
        ensure_templates(*args)
        ensure_vms(*args)
        run_ansible
    when options[:list]
        puts render_inventory(*args)
    end
end
