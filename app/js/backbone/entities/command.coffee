@App.module "Entities", (Entities, App, Backbone, Marionette, $, _) ->

  ## this is another good candidate for a mutator
  ## with stripping out the parent selector

  class Entities.Command extends Entities.Model
    defaults: ->
      indent: 0
      pause: false
      revert: false
      number: 0

    mutators:
      selector: ->
        _.trim @stripParentSelector()

      ## display controls if there isnt an error
      ## and this isnt a clone
      shouldDisplayControls: ->
        not @isCloned()

      truncated: ->
        switch @get("type")
          when "xhr"        then @xhr.responseTextText.length > 40
          when "assertion"  then @get("message").length > 100

      messageTruncated: ->
        return if not message = @get("message")
        _(message).truncate(100, " ")

    initialize: ->
      new Backbone.Chooser(@)

    highlight: (init) ->
      @set "highlight", init

    indent: (indent) ->
      indent = @parent.get("indent")
      @set "indent", indent + 17

    setParent: (parent) ->
      @parent = parent
      @set "hasParent", true
      @parent.set "isParent", true
      @

    hasParent: ->
      !!@get("hasParent")

    isParent: ->
      !!@get("isParent")

    isCloned: ->
      !!@get("isCloned")

    stripParentSelector: ->
      selector = @attributes.selector ? ""

      ## bail if we dont even have a parent
      return selector if not @hasParent()

      parent = @parent.attributes.selector ? ""

      ## replace only the first occurance of the parent selector
      selector.replace parent, ""

    setResponse: (response) ->
      @set "status", @xhr.status
      @set "response", _(@xhr.responseText).truncate(40, " ")
      @response = response

    getPrimaryObjects: ->
      objs = switch @get("type")
        when "dom"        then @el
        when "assertion"  then @getAssertion()
        when "server"     then @getServer()
        when "xhr"        then @getXhrObject()
        when "spy"        then @getSpyObject()

      _([objs]).flatten(true)

    getSnapshot: ->
      @snapshot

    getEl: ->
      @el

    convertToArray: (obj) ->
      _.reduce obj, (memo, value, key) ->
        memo.push ["%c" + key, "font-weight: bold;", value] if value?
        memo
      , []

    getSpyObject: ->
      spy = @spy
      spyCall = @spyCall

      _.defer =>
        @logSpyTableProperties(spy, spyCall)

      @convertToArray
        "Spy:    %O": spy
        "Calls: ": spy.callCount

    logSpyTableProperties: (spy, spyCall) ->
      count = spy.callCount
      return if count is 0

      ## if spyCall is passed in just log out this
      ## specific spyCall as opposed to all of them
      ## use its num - 1 for 0 based indexes
      if spyCall
        @logSpyCall(spy, spyCall.num - 1)
      else
        for i in [0..count - 1]
          @logSpyCall(spy, i)

    logSpyCall: (spy, index) ->
      console.group("Call ##{index + 1}:")
      # console.log.apply(console, @getSpyArgsForCall(spy, i))
      @logSpyProperty("Arguments:  %O", spy.args[index])
      @logSpyProperty("Context:   ", spy.thisValues[index])
      @logSpyProperty("Returned:  ", spy.returnValues[index])

      exception = spy.exceptions[index]
      if exception
        @logSpyProperty("Error:     ", exception)
        @logSpyProperty("Stack:     ", exception.stack)

      console.groupEnd()

    logSpyProperty: (key, value) ->
      console.log "%c#{key}", "color: blue", value

    getXhrObject: ->
      ## return the primary xhr object
      ## if we dont have a response
      return @xhr if not @get("response")

      response = @xhr.responseText

      try
        response = JSON.parse response

      @convertToArray
        "Status:     ": @xhr.status
        "URL:        ": @xhr.url
        "Matched URL:": @response.url
        "Request:    ": @xhr
        "Response:   ": response

    getAssertion: ->
      @convertToArray
        "Subject:  ": @subject
        "Expected: ": @expected
        "Actual:   ": @actual
        "Message:  ": @get("message")

    getServer: ->
      @convertToArray
        "Server:    ": @server
        "Requests:  ": @requests
        "Responses: ": @responses
        "Queue:     ": (@requests.length - @responses.length)

  class Entities.CommandsCollection extends Entities.Collection
    model: Entities.Command

    initialize: ->
      new Backbone.SingleChooser(@)

    ## returns the original command
    ## from this cloned command
    getOriginalByClone: (command) ->
      @get command.get("clonedFrom")

    parentExistsFor: (id) ->
      @get(id)

    getCommandIndex: (command) ->
      @indexOf(command) + 1

    increment: (command) ->
      command.set "number", @maxNumber()

    maxNumber: ->
      ## set to 0 if its undefined
      @_maxNumber ?= 0

      ## incremental by one
      @_maxNumber += 1

    ## check to see if the last parent command
    ## is the passed in parent
    lastParentCommandIsNotParent: (parent, command) ->
      ## loop through this in reverse
      ## cannot reverse the models array
      ## and use _.find because .clone()
      ## is throwing an error
      for model in @models by -1
        ## exclude ourselves since we recursively check
        ## up the parent chains
        if model.get("canBeParent")
          return model isnt parent

    lastParentsAreNotXhr: (parent, command) ->
      for model in @models by -1
        ## if any of the parents arent xhr's return true
        return true if model.get("type") isnt "xhr"

        ## if we eventually make it to our parent then
        ## return false
        return false if model is parent

    cloneParent: (parent) ->
      ## get a clone of our parent but reset its id
      clone = parent.clone()

      ## also remove its number
      clone.unset "number"

      clone.set
        id: _.uniqueId("cloneId")
        isCloned: true
        clonedFrom: parent.id

      _.each ["el", "xhr", "response", "parent"], (prop) ->
        clone[prop] = parent[prop]

      @add clone

    getCommandByType: (attrs) ->
      switch attrs.type
        when "dom"        then @addDom attrs
        when "xhr"        then @addXhr attrs
        when "assertion"  then @addAssertion attrs
        when "server"     then @addServer attrs
        when "spy"        then @addSpy attrs
        else throw new Error("Command .type did not match anything")

    insertParents: (command, parentId, options = {}) ->
      if parent = @parentExistsFor(parentId)

        ## make sure the last command is our parent, if its not
        ## then re-insert it (as a new model) and reset which
        ## one is our parent

        ## right here we need to potentially insert multiple parents
        ## in case we've referenced an ecl object way down the line
        if options.if and options.if.call(@, parent, command)
          ## recursively walk up the parent chain by ensuring we insert
          ## as many parents as necessary to get back to the root command
          @insertParents(parent, parent.parent.id, options) if parent.hasParent()

          parent = @cloneParent(parent)

        command.setParent parent
        command.indent()
        options.onSetParent.call(@, parent) if options.onSetParent

    getIndexByParent: (command) ->
      return if not command.hasParent()

      @getCommandIndex(command.parent)

    anyFailed: ->
      @any (command) -> command.get("error")

    getTotalNumber: ->
      @_maxNumber

    getXhrOptions: (command, options) ->
      ## at the very last minute we splice in this
      ## new command by figuring out what its parents
      ## index is (if this is an xhr)

      index = @getIndexByParent(command)
      options.at = index if index
      options

    addSpy: (attrs) ->
      {spy, spyCall, snapshot} = attrs

      attrs = _(attrs).omit "spy", "spyCall", "snapshot"

      command = new Entities.Command attrs
      command.spy = spy
      command.spyCall = spyCall
      command.snapshot = snapshot

      @insertParents command, attrs.parent,
        if: (parent, cmd) ->
          @lastParentCommandIsNotParent(parent, cmd)

      return command

    addAssertion: (attrs) ->
      {snapshot, el, actual, expected, subject} = attrs

      attrs = _(attrs).omit "snapshot", "el", "actual", "expected", "subject"

      ## instantiate the new model
      command = new Entities.Command attrs
      command.snapshot = snapshot
      command.el = el
      command.actual = actual
      command.expected = expected
      command.subject = subject

      return command

    addDom: (attrs) ->
      {el, snapshot} = attrs

      attrs = _(attrs).omit "el", "snapshot"

      ## instantiate the new model
      command = new Entities.Command attrs
      command.snapshot = snapshot
      command.el = el

      ## if we're chained to an existing id
      ## that means we have a parent
      @insertParents command, attrs.parent,

        ## insert a parent if the last parent command
        ## is not these arguments
        if: (parent, cmd) ->
          @lastParentCommandIsNotParent(parent, cmd)

      return command

    addXhr: (attrs) ->
      {xhr, response, snapshot} = attrs

      attrs = _(attrs).omit "xhr", "response", "snapshot"

      ## instantiate the new model
      command = new Entities.Command attrs
      command.xhr = xhr
      command.snapshot = snapshot

      @insertParents command, attrs.parent,
        ## insert a parent if the last parent commands
        ## are not xhr types
        if: (parent, cmd) ->
          @lastParentsAreNotXhr(parent, cmd)

        ## when the parent is set on this child command
        ## set the response for it
        onSetParent: (parent) ->
          command.setResponse response

      return command

    addServer: (attrs) ->
      {snapshot, requests, responses, server} = attrs

      attrs = _(attrs).omit "requests", "responses", "server"

      command = new Entities.Command attrs
      command.snapshot       = snapshot
      command.requests  = requests
      command.responses = responses
      command.server    = server

      return command

    add: (attrs, type, runnable, hook) ->
      command = attrs
      options = type

      ## if we have both of these methods assume this is
      ## a backbone model
      if command and command.set and command.get
        options = @getXhrOptions(command, options) if command.get("type") is "xhr"

        ## increment the number if its not cloned
        @increment(command) unless command.isCloned()

        return super(command, options)

      return if _.isEmpty attrs

      _.extend attrs,
        type: type
        testId: runnable.cid
        hook: hook

      command = @getCommandByType(attrs)

      super command

    reset: ->
      @_maxNumber = 0
      super

  App.reqres.setHandler "command:entities", ->
    new Entities.CommandsCollection