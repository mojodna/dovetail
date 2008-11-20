# Dovetail 

Dovetail is a toolkit for assembling XMPP components such as bots and PubSub
(XEP-0060) servers.

## Getting Started

Install switchboard:

    $ sudo gem install mojodna-switchboard -s http://gems.github.com

Start the component:

    $ bin/dovetail

You'll need to edit the `DEFAULT_SETTINGS` in `bin/dovetail` to point at a
Jabber server with component access. You'll also need a second Jabber server
that you can connect to as a client in order to make requests to the
component.

(Asynchronously) query a web service with switchboard:

    $ switchboard --jid client@xmpp-server --password pa55word \
        pubsub \
        --server component-server \
        --node "http://github.com/api/v1/json/mojodna/switchboard/commits/master" \
        items

This will query a node on your Jabber server for available (persisted) items.
For "nodes" supported through Dovetail, this means that a GET request will be
made to the URL corresponding to the node name and the response will be
packaged up as a PubSub response.
