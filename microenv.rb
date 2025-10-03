#!/usr/bin/env ruby

ONE_XMLRPC = 'http://10.2.11.40:2633/RPC2'
ONE_AUTH   = 'oneadmin:asd'

TEMPLATE     = 'ubuntu2404'
MICROENV     = 'kvm-ssh'
VERSION      = '7.0'
ID           = 'asd12'
DOMAIN       = 'test'
STEM         = "#{TEMPLATE}-#{MICROENV}-#{VERSION}-#{ID}"
VM_STEM      = STEM
VNET_STEM    = "private-#{STEM}"
VMGROUP_STEM = STEM

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

def combine(a, b)
    (recurse = proc { |a, b|
        case
        when a.is_a?(Hash) && b.is_a?(Hash)
            a.merge(b) { |_, a, b| recurse.call(a, b) }
        when a.is_a?(Array) && b.is_a?(Array)
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
    }).call(a, b)
end

def parse_extra(path = "./#{MICROENV}/extra.yaml")
    require 'erb'
    require 'yaml'
    @extra ||= YAML.load ERB.new(File.read(path), :trim_mode => %[\-]).result(binding)
end

def ensure_vnets(one)
    rc = (pool = OpenNebula::VirtualNetworkPool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    parse_extra['vnets'].each do |it|
        next if pool.find { |f| f.name == it.dig('template', 'NAME') }
        x = OpenNebula::VirtualNetwork.new OpenNebula::VirtualNetwork.build_xml, one
        rc = x.allocate to_one(it.dig('template')), -1
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def ensure_vmgroup(one)
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

def ensure_templates(one)
    rc = (pool = OpenNebula::TemplatePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    exit(-1) unless (b = pool.find { |f| f.name == TEMPLATE })
    parse_extra['vms'].each do |it|
        next if pool.find { |f| f.name == it.dig('template', 'NAME') }
        id = b.clone it.dig('template', 'NAME'), true
        pp(id).then{exit(-1)} if OpenNebula.is_error?(id)
        x = OpenNebula::Template.new OpenNebula::Template.build_xml(id), one
        rc = x.info
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
        update = combine(
            combine(
                x.to_hash.dig('VMTEMPLATE', 'TEMPLATE'),
                it.dig('template')
            ),
            { 'VMGROUP' => { 'VMGROUP_NAME' => VMGROUP_STEM, 'ROLE' => 'undefined' } }
        )
        rc = x.update to_one(update), 0
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def ensure_vms(one)
    rc = (pool1 = OpenNebula::VirtualMachinePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    rc = (pool2 = OpenNebula::TemplatePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    parse_extra['vms'].each do |it|
        next if pool1.find { |f| f.name == it.dig('template', 'NAME') }
        exit(-1) unless (x = pool2.find { |f| f.name == it.dig('template', 'NAME') })
        rc = x.instantiate it.dig('template', 'NAME')
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

if caller.empty?
    require 'opennebula'
    one = OpenNebula::Client.new(ONE_AUTH, ONE_XMLRPC, :sync => true)
    ensure_vnets(one)
    ensure_vmgroup(one)
    ensure_templates(one)
    ensure_vms(one)
end
