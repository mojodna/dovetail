require 'rubygems'
require 'switchboard'
require 'xmpp4r'
require 'xmpp4r/pubsub'
require 'open-uri'

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
        items = Jabber::PubSub::Items.import(items)
        puts "Request for items on #{items.node}"

        # fetch items from the node url provided
        url = REXML::Text.unnormalize(items.node)
        response = open(url).read

        item = Jabber::PubSub::Item.new

        # attempt to treat as XML
        doc = REXML::Document.new(response)
        item.add(doc.root || REXML::CData.new(response))

        resp = iq.answer
        resp.type = :result
        resp.pubsub.first_element("items").add(item)
        deliver(resp)
      elsif create = iq.pubsub.first_element("create")
        node = create.attributes["node"]
        puts "Request for node creation: #{node}"

        # TODO support <configure/> stanzas, blank or otherwise

        resp = Jabber::Iq.new(:result, iq.from)
        resp.from = iq.to # TODO component.domain (elsewhere, too)
        resp.id = iq.id
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
end
