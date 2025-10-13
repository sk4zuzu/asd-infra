#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'erb'
require 'json'
require 'yaml'

ONE_XMLRPC = 'http://10.2.11.40:2633/RPC2'
ONE_AUTH   = 'oneadmin:asd'

TEMPLATE     = 'ubuntu2404'
MICROENV     = 'kvm-fed'
FLAVORS      = ENV.fetch('FLAVORS', '')
FEDENV       = ENV.fetch('FEDENV', '')
VERSION      = '7.0'
ID           = 'asd12'
DOMAIN       = 'test'
STEM         = [TEMPLATE, MICROENV, *FLAVORS.split(%[\+]), *VERSION.split(%[\.]), ID].reject(&:empty?).join(%[\-])
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

def resolve_paths(flavors)
    raise unless (dir = File.realpath(Dir.exist?(t = "./#{MICROENV}/") ? t : './')).end_with?(MICROENV)
    Dir["#{dir}/*"].each_with_object({}) do |path, acc|
        name, *tags = File.basename(path).split(%[\#])
        next unless %w[ ansible.cfg
                        bootstrap.yml
                        defaults.yml
                        infra.yml
                        inventory.yml
                        site.yml ].include?(name)
        acc[path] = {
            :name    => name,
            :flavors => (x = tags.reject { |tag| tag.to_s[/^\d+$/] }).empty? ? [''] : x,
            :fedenvs => (y = tags.select { |tag| tag.to_s[/^\d+$/] }).empty? ? [''] : y
        }
    end.then do |by_path|
        # group files by flavor
        (by_path.map { |_, v| v[:flavors] }).flatten.uniq.each_with_object({}) do |flavor, acc|
            acc[flavor] = by_path.select { |_, v| v[:flavors].include?(flavor) }
        end
    end.then do |by_flavor|
        # group files by fedenv for each flavor
        by_flavor.each_with_object({}) do |(flavor, vv), acc|
            (vv.map { |_, v| v[:fedenvs] }).flatten.uniq.each do |fedenv|
                acc[flavor] ||= {}
                acc[flavor][fedenv] = by_flavor[flavor].select { |k, v| v[:fedenvs].include?(fedenv) }
            end
        end
    end.then do |by_flavor|
        # convert path -> name mapping to name -> path + clean it up
        by_flavor.each do |flavor, by_fedenv|
            by_fedenv.each do |fedenv, by_path|
                by_name = by_path.each_with_object({}) do |(path, v), acc|
                    acc[v[:name]] = path
                end
                by_fedenv[fedenv].replace by_name
            end
        end
    end.then do |by_flavor|
        # pick and merge together flavors specified by the caller
        by_fedenv = ([''] + flavors.to_s.split(%[\+])).uniq.then do |ff|
            by_flavor.slice(*ff).then do |sliced|
                raise unless (sliced.keys - ff).empty?
                combine *sliced.values
            end
        end
        # merge each specific fedenv with defaults
        (by_fedenv.keys - ['']).each do |fedenv|
            m = combine (by_fedenv.dig('') || {}),
                        by_fedenv[fedenv]
            by_fedenv[fedenv].replace m
        end
        by_fedenv
    end
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

def parse_infra_yml(path, b)
    YAML.load ERB.new(File.read(path), :trim_mode => %[\-]).result(b)
end

def ensure_vnets(one, infra_yml)
    rc = (pool = OpenNebula::VirtualNetworkPool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    infra_yml['vnets'].each do |it|
        next if pool.find { |f| f.name == it.dig('template', 'NAME') }
        x = OpenNebula::VirtualNetwork.new OpenNebula::VirtualNetwork.build_xml, one
        rc = x.allocate to_one(it.dig('template')), -1
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def ensure_vmgroup(one, infra_yml)
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

def ensure_templates(one, infra_yml)
    rc = (pool = OpenNebula::TemplatePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    exit(-1) unless (b = pool.find { |f| f.name == TEMPLATE })
    infra_yml['vms'].each do |it|
        next if pool.find { |f| f.name == it.dig('template', 'NAME') }
        id = b.clone it.dig('template', 'NAME'), true
        pp(id).then{exit(-1)} if OpenNebula.is_error?(id)
        x = OpenNebula::Template.new OpenNebula::Template.build_xml(id), one
        rc = x.info
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
        update = combine x.to_hash.dig('VMTEMPLATE', 'TEMPLATE'),
                         it.dig('template'),
                         { 'VMGROUP' => { 'VMGROUP_NAME' => VMGROUP_STEM, 'ROLE' => 'undefined' } },
                         :merge_lists => true
        rc = x.update to_one(update), 0
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def ensure_vms(one, infra_yml)
    rc = (pool1 = OpenNebula::VirtualMachinePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    rc = (pool2 = OpenNebula::TemplatePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    infra_yml['vms'].each do |it|
        next if pool1.find { |f| f.name == it.dig('template', 'NAME') }
        exit(-1) unless (x = pool2.find { |f| f.name == it.dig('template', 'NAME') })
        rc = x.instantiate it.dig('template', 'NAME')
        pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    end
end

def build_groups(inventory_yml)
    inventory_yml.each_with_object({}) do |(g, v), acc|
        acc[g] ||= {}
        acc[g]['hosts']    = v['hosts'].keys    unless v['hosts'].nil?
        acc[g]['children'] = v['children'].keys unless v['children'].nil?
    end.then do |groups|
        children = [
            ['ungrouped'],
            groups['all']['children'].to_a,
            (groups.keys - ['all']).each_with_object([]) do |g, acc|
                next unless (groups.select { |_, v| v['children'].to_a.include?(g) }).empty?
                acc << g
            end
        ].flatten.uniq
        combine groups, { 'all' => { 'children' => children } }
    end
end

def build_hostvars(inventory_yml)
    (recurse = proc { |node, vars, acc|
        node&.dig('children').to_h.keys.each do |g|
            m = combine vars.to_h,
                        node&.dig('vars').to_h
            recurse.call inventory_yml[g], m, acc
        end
        node&.dig('hosts').to_h.each do |h, v|
            m = combine (acc[h] ||= {}),
                        vars.to_h,
                        node&.dig('vars').to_h,
                        v.to_h
            acc[h].replace m
        end
    }).call inventory_yml['all'], {}, (hostvars = {})
    hostvars
end

def build_inventory(inventory_yml)
    groups = build_groups(inventory_yml)

    inventory_yml['all']['children'] = groups['all']['children'].to_h { |g| [g, {}] }

    hostvars = build_hostvars(inventory_yml)

    combine ({ '_meta' => { 'hostvars' => hostvars } }), groups
end

def parse_inventory_yml(path, b)
    YAML.load ERB.new(File.read(path), :trim_mode => %[\-]).result(b)
end

def render_inventory(one, paths)
    rc = (pool = OpenNebula::VirtualMachinePool.new(one)).info
    pp(rc).then{exit(-1)} if OpenNebula.is_error?(rc)
    parse_infra_yml(paths[FEDENV]['infra.yml'], binding)['vms'].each_with_object([]) do |it, acc|
        next unless (vm = pool.find { |f| f.name == it.dig('template', 'NAME') })
        h = vm.to_hash['VM']
        acc << {
            'inventory_hostname' => h.dig('NAME'),
            'ansible_host'       => [h.dig('TEMPLATE', 'NIC')].flatten.dig(0, 'IP')
        }
    end.then do |vms|
        JSON.dump build_inventory(
            parse_inventory_yml(paths[FEDENV]['inventory.yml'], binding)
        )
    end
end

def run_ansible(paths, fedenv)
    Dir.chdir("./#{MICROENV}/") do
        env = {
            'FLAVORS'        => FLAVORS,
            'FEDENV'         => fedenv,
            'ANSIBLE_CONFIG' => paths[fedenv]['ansible.cfg']
        }
        raise unless system env, 'ansible-playbook', '-v', paths[fedenv]['site.yml']
    end
end

def microenv_apply(one, paths)
    case paths.length
    when 0 then raise
    when 1
        [FEDENV]
    else
        (paths.keys - ['']).map(&:to_i).sort.map(&:to_s)
    end.each do |fedenv|
        infra_yml = parse_infra_yml paths[fedenv]['infra.yml'], binding
        ensure_vnets one, infra_yml
        ensure_vmgroup one, infra_yml
        ensure_templates one, infra_yml
        ensure_vms one, infra_yml
        run_ansible paths, fedenv
    end
end

if caller.empty?
    options = {}
    OptionParser.new do |opt|
        opt.on('--host HOSTNAME') { raise NotImplementedError }
        opt.on('--apply')         { options[:apply] = true }
        opt.on('--list')          { options[:list] = true }
    end.parse!

    paths = resolve_paths FLAVORS

    require 'opennebula'

    one = OpenNebula::Client.new ONE_AUTH, ONE_XMLRPC, :sync => true

    case
    when options[:apply] then microenv_apply(one, paths)
    when options[:list]  then puts render_inventory(one, paths)
    else raise
    end
end
