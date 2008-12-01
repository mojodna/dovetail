require 'rubygems'
require 'switchboard'
require 'xmpp4r'
require 'xmpp4r/pubsub'
require 'open-uri'
require 'pp'

class Dovetail < Switchboard::Component
  attr_reader :component, :settings

  DEFAULT_SETTINGS = {
    "component.domain" => "ubuntu.local",
    "component.host"   => "ubuntu.local",
    "component.port"   => 5288,
    "component.secret" => "secret",
    "component.status" => ""
  }

  def initialize(settings = {})
    super(settings, true)
    plug!(DebugJack)
    @settings = DEFAULT_SETTINGS.merge(settings)

    @component = Jabber::Component.new(settings["component.domain"])

    on_presence(:presence_handler)
    on_iq(:iq_handler)
  end

  # override this if you want to do deferred sending (via queues or whatnot)
  def deliver(data)
    puts ">> #{data.to_s}"
    component.send(data)
  end

protected

  def message_handler(message)
    # don't do anything here, but if / when we want to handle messages, do it here.
  end

  def presence_handler(presence)
    case presence.type
    when :error

      puts "An error occurred: #{presence.to_s}"

    when :probe
      # client is probing us to see if we're online

      # send a basic presence response
      p = Jabber::Presence.new
      p.to = presence.from
      p.from = presence.to
      p.id = presence.id
      p.status = settings["component.status"]
      deliver(p)

    when :subscribe
      # client has subscribed to us

      # First send a "you're subscribed" response
      p = Jabber::Presence.new
      p.to = presence.from
      p.from = presence.to
      p.type = :subscribed
      p.id = presence.id
      deliver(p)

      # follow it up with a presence request
      p = Jabber::Presence.new
      p.to = presence.from
      p.from = presence.to
      p.id = "fe_#{rand(2**32)}"
      p.status = FIRE_EAGLE_CONFIG.jabber_status
      deliver(p)

      # Then send a "please let me subscribe to you" request
      p = Jabber::Presence.new
      p.to = presence.from
      p.from = presence.to
      p.type = :subscribe
      p.id = "fe_#{rand(2**32)}"
      deliver(p)

    when :subscribed
      # now we've got a mutual subscription relationship
    when :unavailable
      # client has gone offline

      update_presence("unavailable", presence.from)

    when :unsubscribe
      # client wants to unsubscribe from us

      # send a "you're unsubscribed" response
      p = Jabber::Presence.new
      p.to = presence.from
      p.from = presence.to
      p.type = :unsubscribed
      p.id = presence.id
      deliver(p)

    when :unsubscribed
      # client has unsubscribed from us
    else

      # client is available
      update_presence((presence.show || :online).to_s, presence.from)

    end
  end

  def iq_handler(iq)
    if iq.pubsub
      if items = iq.pubsub.first_element("items")
        puts "Request for items on #{items.node} (#{items.max_items || "all"})"

        resp = iq.answer

        begin
          items = get_items_from_node(items.node, items.max_items)

          resp.type = :result
          items_node = resp.pubsub.first_element("items")
          items.each do |item|
            items_node.add(item)
          end
        rescue Jabber::ServerError => e
          resp.type = :error
          resp.add(e.error)
        end

        deliver(resp)

      elsif create = iq.pubsub.first_element("create")

        node = create.attributes["node"]
        puts "Request for node creation: #{node}"

        # TODO support <configure/> stanzas, blank or otherwise

        resp = Jabber::Iq.new(:result, iq.from)
        resp.from = iq.to # TODO component.domain (elsewhere, too)
        resp.id = iq.id
        deliver(resp)

      elsif publish = iq.pubsub.first_element("publish")

        resp = iq.answer

        begin
          # supporting batch queries involves wrapping a transaction around all rack requests
          if publish.items.length > 1
            error = Jabber::ErrorResponse.new("not-allowed")
            error.add_element("max-items-exceeded").add_namespace("http://jabber.org/protocol/pubsub#errors")
            raise Jabber::ServerError, error
          end

          item = publish_item_to_node(publish.node, publish.items[0])

          resp.type = :result
          pub = resp.pubsub.first_element("publish")
          pub.delete_element("item")
          pub.add(item)
        rescue Jabber::ServerError => e
          resp.type = :error
          resp.add(e.error)
        end

        deliver(resp)

      elsif retract = iq.pubsub.first_element("retract")

        node = retract.node
        puts "Retracting from node: #{node}"

        resp = iq.answer

        begin
          # supporting batch queries involves wrapping a transaction around all rack requests
          if retract.items.length > 1
            error = Jabber::ErrorResponse.new("not-allowed")
            error.add_element("max-items-exceeded").add_namespace("http://jabber.org/protocol/pubsub#errors")
            raise Jabber::ServerError, error
          end

          item = retract_item_from_node(node, retract.items[0].id)

          resp.type = :result
          pub = resp.pubsub.first_element("retract")
          pub.delete_element("item")
          pub.add(item)
        rescue Jabber::ServerError => e
          resp.type = :error
          resp.add(e.error)
        end

        deliver(resp)

      else
        puts "Received a pubsub message"
        puts iq.to_s
        # TODO not-supported
        not_implemented(iq)
      end
    else
      # unrecognized iq
      not_implemented(iq)
    end
  end

  def update_presence(presence, jid)
  end

  # respond to a request by claiming that it's not implemented
  def not_implemented(iq)
    resp = iq.answer
    resp.type = :error
    resp.add(Jabber::ErrorResponse.new("feature-not-implemented"))
    deliver(resp)
  end

  def rack_request(env, &block)
    output = $stdout # (Logging)
    request  = ActionController::RackRequest.new(env)
    response = ActionController::RackResponse.new(request)

    controller = ActionController::Routing::Routes.recognize(request)
    pp request.path_parameters # => hash containing info about the request
    controller.process(request, response).out(output)

    puts "Response was: #{response.body}"
    puts "Status was: #{response.status}"

    case response.status.to_i
    when 200
      yield response
    when 404
      raise Jabber::ServerError, Jabber::ErrorResponse.new("item-not-found")
    else
      puts "Unhandled status code #{response.status}"
      raise Jabber::ServerError, Jabber::ErrorResponse.new("internal-server-error", response.status)
    end
  end

  def get_items_from_node(node, max_items = nil)
    env = {
      "REQUEST_METHOD" => "GET",
      "HTTP_ACCEPT"    => Mime::XML,
      "REQUEST_URI"    => node,
      "QUERY_STRING"   => max_items ? "per_page=#{max_items}" : "",
    }

    rack_request(env) do |response|
      items = []

      doc = REXML::Document.new(response.body)

      # special casing for ActiveRecord's default #to_xml serialization
      if doc.root.has_elements?
        collection_name = doc.root.name
        item_name = collection_name.singularize

        if doc.root.elements["/#{collection_name}/#{item_name}"]
          doc.root.each_element(item_name) do |item|
            item_node = Jabber::PubSub::Item.new(REXML::XPath.first(item, "//id").text)
            item_node.add(item)
            items << item_node
          end
        else
          item_node = Jabber::PubSub::Item.new(REXML::XPath.first(doc.root, "//id").text)
          item_node.add(doc.root)
          items << item_node
        end
      end

      items
    end
  end

  def publish_item_to_node(node, item)
    puts "Publishing to node: #{node}"
    # TODO am I publishing to an existing node or a new node?

    if item.id
      puts "Publishing with id #{item.id}"
    else
      puts "Publishing with no id."
    end

    puts "Data:"
    data = REXML::Text.unnormalize(item.text).to_s
    puts data

    env = {
      "REQUEST_METHOD" => (item.id ? "PUT" : "POST"),
      "CONTENT_TYPE"   => Mime::XML,
      "CONTENT_LENGTH" => data.length,
      "REQUEST_URI"    => [node, item.id] * "/",
      "RAW_POST_DATA"  => data,
    }

    rack_request(env) do |response|
      doc = REXML::Document.new(response.body)
      if doc.root
        id = REXML::XPath.first(doc.root, "//id").text
      else
        id = nil
      end

      Jabber::PubSub::Item.new(id)
    end
  end

  def retract_item_from_node(node, id)
    env = {
      "REQUEST_METHOD" => "DELETE",
      "HTTP_ACCEPT"    => Mime::XML,
      "CONTENT_TYPE"   => Mime::XML,
      "REQUEST_URI"    => [node, id] * "/",
    }

    rack_request(env) do |response|
      Jabber::PubSub::Item.new(id)
    end
  end
end
