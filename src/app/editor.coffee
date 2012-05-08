{View, $$} = require 'space-pen'
Buffer = require 'buffer'
CompositeCursor = require 'composite-cursor'
CompositeSelection = require 'composite-selection'
Gutter = require 'gutter'
Renderer = require 'renderer'
Point = require 'point'
Range = require 'range'

$ = require 'jquery'
_ = require 'underscore'

module.exports =
class Editor extends View
  @idCounter: 1

  @content: (params) ->
    @div class: @classes(params), tabindex: -1, =>
      @input class: 'hidden-input', outlet: 'hiddenInput'
      @div class: 'flexbox', =>
        @subview 'gutter', new Gutter
        @div class: 'scroller', outlet: 'scroller', =>
          @div class: 'lines', outlet: 'lines', =>

  @classes: ({mini}) ->
    classes = ['editor']
    classes.push 'mini' if mini
    classes.join(' ')

  vScrollMargin: 2
  hScrollMargin: 10
  softWrap: false
  lineHeight: null
  charWidth: null
  charHeight: null
  cursor: null
  selection: null
  buffer: null
  highlighter: null
  renderer: null
  autoIndent: null
  lineCache: null
  isFocused: false
  softTabs: true
  tabText: '  '
  editSessions: null
  attached: false

  @deserialize: (viewState, rootView) ->
    viewState = _.clone(viewState)
    viewState.editSessions = viewState.editSessions.map (editSession) ->
      editSession = _.clone(editSession)
      editSession.buffer = Buffer.deserialize(editSession.buffer, rootView.project)
      editSession

    new Editor(viewState)

  initialize: ({editSessions, activeEditSessionIndex, buffer, isFocused, @mini}) ->
    requireStylesheet 'editor.css'
    requireStylesheet 'theme/twilight.css'

    @id = Editor.idCounter++
    @bindKeys()
    @autoIndent = true
    @buildCursorAndSelection()
    @handleEvents()

    @editSessions = editSessions ? []
    if activeEditSessionIndex?
      @loadEditSession(activeEditSessionIndex)
    else if buffer?
      @setBuffer(buffer)
    else
      @setBuffer(new Buffer)

    @isFocused = isFocused if isFocused?

  serialize: ->
    @saveCurrentEditSession()
    { viewClass: "Editor", editSessions: @serializeEditSessions(), @activeEditSessionIndex, @isFocused }

  serializeEditSessions: ->
    @editSessions.map (session) ->
      session = _.clone(session)
      session.buffer = session.buffer.serialize()
      session

  copy: ->
    Editor.deserialize(@serialize(), @rootView())

  bindKeys: ->
    editorBindings =
      'save': @save
      'move-right': @moveCursorRight
      'move-left': @moveCursorLeft
      'move-down': @moveCursorDown
      'move-up': @moveCursorUp
      'move-to-next-word': @moveCursorToNextWord
      'move-to-previous-word': @moveCursorToPreviousWord
      'select-right': @selectRight
      'select-left': @selectLeft
      'select-up': @selectUp
      'select-down': @selectDown
      'newline': @insertNewline
      'tab': @insertTab
      'indent-selected-rows': @indentSelectedRows
      'outdent-selected-rows': @outdentSelectedRows
      'backspace': @backspace
      'backspace-to-beginning-of-word': @backspaceToBeginningOfWord
      'delete': @delete
      'delete-to-end-of-word': @deleteToEndOfWord
      'cut-to-end-of-line': @cutToEndOfLine
      'cut': @cutSelection
      'copy': @copySelection
      'paste': @paste
      'undo': @undo
      'redo': @redo
      'toggle-soft-wrap': @toggleSoftWrap
      'fold-selection': @foldSelection
      'split-left': @splitLeft
      'split-right': @splitRight
      'split-up': @splitUp
      'split-down': @splitDown
      'close': @close
      'show-next-buffer': @loadNextEditSession
      'show-previous-buffer': @loadPreviousEditSession

      'move-to-top': @moveCursorToTop
      'move-to-bottom': @moveCursorToBottom
      'move-to-beginning-of-line': @moveCursorToBeginningOfLine
      'move-to-end-of-line': @moveCursorToEndOfLine
      'move-to-first-character-of-line': @moveCursorToFirstCharacterOfLine
      'move-to-beginning-of-word': @moveCursorToBeginningOfWord
      'move-to-end-of-word': @moveCursorToEndOfWord
      'select-to-top': @selectToTop
      'select-to-bottom': @selectToBottom
      'select-to-end-of-line': @selectToEndOfLine
      'select-to-beginning-of-line': @selectToBeginningOfLine
      'select-to-end-of-word': @selectToEndOfWord
      'select-to-beginning-of-word': @selectToBeginningOfWord

    for name, method of editorBindings
      do (name, method) =>
        @on name, => method.call(this); false

  buildCursorAndSelection: ->
    @compositeSelection = new CompositeSelection(this)
    @compositeCursor = new CompositeCursor(this)

  addCursorAtScreenPosition: (screenPosition) ->
    @compositeCursor.addCursorAtScreenPosition(screenPosition)

  addCursorAtBufferPosition: (bufferPosition) ->
    @compositeCursor.addCursorAtBufferPosition(bufferPosition)

  addSelectionForCursor: (cursor) ->
    @compositeSelection.addSelectionForCursor(cursor)

  handleEvents: ->
    @on 'focus', =>
      @hiddenInput.focus()
      false

    @hiddenInput.on 'focus', =>
      @rootView()?.editorFocused(this)
      @isFocused = true
      @addClass 'focused'

    @hiddenInput.on 'focusout', =>
      @isFocused = false
      @removeClass 'focused'

    @lines.on 'mousedown', '.fold-placeholder', (e) =>
      @destroyFold($(e.currentTarget).attr('foldId'))
      false

    @lines.on 'mousedown', (e) =>
      clickCount = e.originalEvent.detail

      if clickCount == 1
        screenPosition = @screenPositionFromMouseEvent(e)
        if e.metaKey
          @addCursorAtScreenPosition(screenPosition)
        else if e.shiftKey
          @selectToScreenPosition(@screenPositionFromMouseEvent(e))
        else
          @setCursorScreenPosition(screenPosition)
      else if clickCount == 2
        if e.shiftKey
          @compositeSelection.getLastSelection().expandOverWord()
        else
          @compositeSelection.getLastSelection().selectWord()
      else if clickCount >= 3
        if e.shiftKey
          @compositeSelection.getLastSelection().expandOverLine()
        else
          @compositeSelection.getLastSelection().selectLine()

      @selectOnMousemoveUntilMouseup()

    @on "textInput", (e) =>
      @insertText(e.originalEvent.data)
      false

    @scroller.on 'scroll', =>
      @gutter.scrollTop(@scroller.scrollTop())
      if @scroller.scrollLeft() == 0
        @gutter.removeClass('drop-shadow')
      else
        @gutter.addClass('drop-shadow')

  afterAttach: (onDom) ->
    return if @attached or not onDom
    @attached = true
    @calculateDimensions()
    @hiddenInput.width(@charWidth)
    @setMaxLineLength() if @softWrap
    @focus() if @isFocused
    @trigger 'editor-open', [this]

  rootView: ->
    @parents('#root-view').view()

  selectOnMousemoveUntilMouseup: ->
    moveHandler = (e) => @selectToScreenPosition(@screenPositionFromMouseEvent(e))
    @on 'mousemove', moveHandler
    $(document).one 'mouseup', =>
      @off 'mousemove', moveHandler
      reverse = @compositeSelection.getLastSelection().isReversed()
      @compositeSelection.mergeIntersectingSelections({reverse})
      @syncCursorAnimations()

  renderLines: ->
    @lineCache = []
    @lines.find('.line').remove()
    @insertLineElements(0, @buildLineElements(0, @getLastScreenRow()))

  getScreenLines: ->
    @renderer.getLines()

  linesForRows: (start, end) ->
    @renderer.linesForRows(start, end)

  screenLineCount: ->
    @renderer.lineCount()

  getLastScreenRow: ->
    @screenLineCount() - 1

  setBuffer: (buffer) ->
    if @buffer
      @saveCurrentEditSession()
      @unsubscribeFromBuffer()

    @buffer = buffer
    @trigger 'editor-path-change'
    @buffer.on "path-change.editor#{@id}", => @trigger 'editor-path-change'

    @renderer = new Renderer(@buffer, { maxLineLength: @calcMaxLineLength(), tabText: @tabText })
    @renderLines()
    @gutter.renderLineNumbers()

    @loadEditSessionForBuffer(@buffer)

    @buffer.on "change.editor#{@id}", (e) => @handleBufferChange(e)
    @renderer.on 'change', (e) => @handleRendererChange(e)

  editSessionForBuffer: (buffer) ->
    for editSession, index in @editSessions
      return [editSession, index] if editSession.buffer == buffer
    [undefined, -1]

  loadEditSessionForBuffer: (buffer) ->
    [editSession, index] = @editSessionForBuffer(buffer)
    if editSession
      @activeEditSessionIndex = index
    else
      @editSessions.push({ buffer })
      @activeEditSessionIndex = @editSessions.length - 1
    @loadEditSession()

  loadNextEditSession: ->
    nextIndex = (@activeEditSessionIndex + 1) % @editSessions.length
    @loadEditSession(nextIndex)

  loadPreviousEditSession: ->
    previousIndex = @activeEditSessionIndex - 1
    previousIndex = @editSessions.length - 1 if previousIndex < 0
    @loadEditSession(previousIndex)

  loadEditSession: (index=@activeEditSessionIndex) ->
    editSession = @editSessions[index]
    throw new Error("Edit session not found") unless editSession
    @setBuffer(editSession.buffer) unless @buffer == editSession.buffer
    @setCursorScreenPosition(editSession.cursorScreenPosition ? [0, 0])
    @scroller.scrollTop(editSession.scrollTop ? 0)
    @scroller.scrollLeft(editSession.scrollLeft ? 0)
    @activeEditSessionIndex = index

  saveCurrentEditSession: ->
    @editSessions[@activeEditSessionIndex] =
      buffer: @buffer
      cursorScreenPosition: @getCursorScreenPosition()
      scrollTop: @scroller.scrollTop()
      scrollLeft: @scroller.scrollLeft()

  handleBufferChange: (e) ->
    @compositeCursor.handleBufferChange(e)
    @compositeSelection.handleBufferChange(e)

  handleRendererChange: (e) ->
    { oldRange, newRange } = e
    unless newRange.isSingleLine() and newRange.coversSameRows(oldRange)
      @gutter.renderLineNumbers(@getScreenLines())

    @compositeCursor.updateBufferPosition() unless e.bufferChanged

    lineElements = @buildLineElements(newRange.start.row, newRange.end.row)
    @replaceLineElements(oldRange.start.row, oldRange.end.row, lineElements)

  buildLineElements: (startRow, endRow) ->
    charWidth = @charWidth
    charHeight = @charHeight
    lines = @renderer.linesForRows(startRow, endRow)
    $$ ->
      for line in lines
        @div class: 'line', =>
          appendNbsp = true
          for token in line.tokens
            if token.type is 'fold-placeholder'
              @span '   ', class: 'fold-placeholder', style: "width: #{3 * charWidth}px; height: #{charHeight}px;", 'foldId': token.fold.id, =>
                @div class: "ellipsis", => @raw "&hellip;"
            else
              appendNbsp = false
              @span { class: token.type.replace('.', ' ') }, token.value
          @raw '&nbsp;' if appendNbsp

  insertLineElements: (row, lineElements) ->
    @spliceLineElements(row, 0, lineElements)

  replaceLineElements: (startRow, endRow, lineElements) ->
    @spliceLineElements(startRow, endRow - startRow + 1, lineElements)

  spliceLineElements: (startRow, rowCount, lineElements) ->
    endRow = startRow + rowCount
    elementToInsertBefore = @lineCache[startRow]
    elementsToReplace = @lineCache[startRow...endRow]
    @lineCache[startRow...endRow] = lineElements?.toArray() or []

    lines = @lines[0]
    if lineElements
      fragment = document.createDocumentFragment()
      lineElements.each -> fragment.appendChild(this)
      if elementToInsertBefore
        lines.insertBefore(fragment, elementToInsertBefore)
      else
        lines.appendChild(fragment)

    elementsToReplace.forEach (element) =>
      lines.removeChild(element)

  getLineElement: (row) ->
    @lineCache[row]

  toggleSoftWrap: ->
    @setSoftWrap(not @softWrap)

  calcMaxLineLength: ->
    if @softWrap
      Math.floor(@scroller.width() / @charWidth)
    else
      Infinity

  setMaxLineLength: (maxLineLength) ->
    maxLineLength ?= @calcMaxLineLength()
    @renderer.setMaxLineLength(maxLineLength) if maxLineLength

  createFold: (range) ->
    @renderer.createFold(range)

  setSoftWrap: (@softWrap, maxLineLength=undefined) ->
    @setMaxLineLength(maxLineLength)
    if @softWrap
      @addClass 'soft-wrap'
      @_setMaxLineLength = => @setMaxLineLength()
      $(window).on 'resize', @_setMaxLineLength
    else
      @removeClass 'soft-wrap'
      $(window).off 'resize', @_setMaxLineLength

  save: ->
    if not @buffer.getPath()
      path = $native.saveDialog()
      return if not path
      @buffer.saveAs(path)
    else
      @buffer.save()

  clipScreenPosition: (screenPosition, options={}) ->
    @renderer.clipScreenPosition(screenPosition, options)

  pixelPositionForScreenPosition: (position) ->
    position = Point.fromObject(position)
    { top: position.row * @lineHeight, left: position.column * @charWidth }

  pixelOffsetForScreenPosition: (position) ->
    {top, left} = @pixelPositionForScreenPosition(position)
    offset = @lines.offset()
    {top: top + offset.top, left: left + offset.left}

  screenPositionFromPixelPosition: ({top, left}) ->
    screenPosition = new Point(Math.floor(top / @lineHeight), Math.floor(left / @charWidth))

  screenPositionForBufferPosition: (position, options) ->
    @renderer.screenPositionForBufferPosition(position, options)

  bufferPositionForScreenPosition: (position, options) ->
    @renderer.bufferPositionForScreenPosition(position, options)

  screenRangeForBufferRange: (range) ->
    @renderer.screenRangeForBufferRange(range)

  bufferRangeForScreenRange: (range) ->
    @renderer.bufferRangeForScreenRange(range)

  bufferRowsForScreenRows: ->
    @renderer.bufferRowsForScreenRows()

  screenPositionFromMouseEvent: (e) ->
    { pageX, pageY } = e
    @screenPositionFromPixelPosition
      top: pageY - @scroller.offset().top + @scroller.scrollTop()
      left: pageX - @scroller.offset().left + @scroller.scrollLeft()

  calculateDimensions: ->
    fragment = $('<div class="line" style="position: absolute; visibility: hidden;"><span>x</span></div>')
    @lines.append(fragment)
    @charWidth = fragment.width()
    @charHeight = fragment.find('span').height()
    @lineHeight = fragment.outerHeight()
    fragment.remove()

  getCursors: -> @compositeCursor.getCursors()
  moveCursorUp: -> @compositeCursor.moveUp()
  moveCursorDown: -> @compositeCursor.moveDown()
  moveCursorRight: -> @compositeCursor.moveRight()
  moveCursorLeft: -> @compositeCursor.moveLeft()
  moveCursorToNextWord: -> @compositeCursor.moveToNextWord()
  moveCursorToBeginningOfWord: -> @compositeCursor.moveToBeginningOfWord()
  moveCursorToEndOfWord: -> @compositeCursor.moveToEndOfWord()
  moveCursorToTop: -> @compositeCursor.moveToTop()
  moveCursorToBottom: -> @compositeCursor.moveToBottom()
  moveCursorToBeginningOfLine: -> @compositeCursor.moveToBeginningOfLine()
  moveCursorToFirstCharacterOfLine: -> @compositeCursor.moveToFirstCharacterOfLine()
  moveCursorToEndOfLine: -> @compositeCursor.moveToEndOfLine()
  setCursorScreenPosition: (position) -> @compositeCursor.setScreenPosition(position)
  getCursorScreenPosition: -> @compositeCursor.getCursor().getScreenPosition()
  setCursorBufferPosition: (position) -> @compositeCursor.setBufferPosition(position)
  getCursorBufferPosition: -> @compositeCursor.getCursor().getBufferPosition()

  getSelection: (index) -> @compositeSelection.getSelection(index)
  getSelections: -> @compositeSelection.getSelections()
  getSelectionsOrderedByBufferPosition: -> @compositeSelection.getSelectionsOrderedByBufferPosition()
  getLastSelectionInBuffer: -> @compositeSelection.getLastSelectionInBuffer()
  getSelectedText: -> @compositeSelection.getSelection().getText()
  setSelectionBufferRange: (bufferRange, options) -> @compositeSelection.setBufferRange(bufferRange, options)
  setSelectedBufferRanges: (bufferRanges) -> @compositeSelection.setBufferRanges(bufferRanges)
  addSelectionForBufferRange: (bufferRange, options) -> @compositeSelection.addSelectionForBufferRange(bufferRange, options)
  selectRight: -> @compositeSelection.selectRight()
  selectLeft: -> @compositeSelection.selectLeft()
  selectUp: -> @compositeSelection.selectUp()
  selectDown: -> @compositeSelection.selectDown()
  selectToTop: -> @compositeSelection.selectToTop()
  selectToBottom: -> @compositeSelection.selectToBottom()
  selectToBeginningOfLine: -> @compositeSelection.selectToBeginningOfLine()
  selectToEndOfLine: -> @compositeSelection.selectToEndOfLine()
  selectToBeginningOfWord: -> @compositeSelection.selectToBeginningOfWord()
  selectToEndOfWord: -> @compositeSelection.selectToEndOfWord()
  selectToScreenPosition: (position) -> @compositeSelection.selectToScreenPosition(position)
  clearSelections: -> @compositeSelection.clearSelections()
  backspace: -> @compositeSelection.backspace()
  backspaceToBeginningOfWord: -> @compositeSelection.backspaceToBeginningOfWord()
  delete: -> @compositeSelection.delete()
  deleteToEndOfWord: -> @compositeSelection.deleteToEndOfWord()
  cutToEndOfLine: -> @compositeSelection.cutToEndOfLine()

  setText: (text) -> @buffer.setText(text)
  getText: -> @buffer.getText()
  getLastBufferRow: -> @buffer.getLastRow()
  getTextInRange: (range) -> @buffer.getTextInRange(range)
  getEofPosition: -> @buffer.getEofPosition()
  lineForBufferRow: (row) -> @buffer.lineForRow(row)
  lineLengthForBufferRow: (row) -> @buffer.lineLengthForRow(row)
  rangeForBufferRow: (row) -> @buffer.rangeForRow(row)
  scanInRange: (args...) -> @buffer.scanInRange(args...)
  backwardsScanInRange: (args...) -> @buffer.backwardsScanInRange(args...)

  insertText: (text) ->
    @compositeSelection.insertText(text)

  insertNewline: ->
    @insertText('\n')

  insertTab: ->
    if @getSelection().isEmpty()
      if @softTabs
        @compositeSelection.insertText(@tabText)
      else
        @compositeSelection.insertText('\t')
    else
      @compositeSelection.indentSelectedRows()

  indentSelectedRows: -> @compositeSelection.indentSelectedRows()
  outdentSelectedRows: -> @compositeSelection.outdentSelectedRows()

  cutSelection: -> @compositeSelection.cut()
  copySelection: -> @compositeSelection.copy()
  paste: -> @insertText($native.readFromPasteboard())

  foldSelection: -> @getSelection().fold()

  undo: ->
    if ranges = @buffer.undo()
      @setSelectedBufferRanges(ranges)

  redo: ->
    if ranges = @buffer.redo()
      @setSelectedBufferRanges(ranges)

  destroyFold: (foldId) ->
    fold = @renderer.foldsById[foldId]
    fold.destroy()
    @setCursorBufferPosition(fold.start)

  splitLeft: ->
    @pane()?.splitLeft(@copy()).wrappedView

  splitRight: ->
    @pane()?.splitRight(@copy()).wrappedView

  splitUp: ->
    @pane()?.splitUp(@copy()).wrappedView

  splitDown: ->
    @pane()?.splitDown(@copy()).wrappedView

  pane: ->
    @parent('.pane').view()

  close: ->
    @remove() unless @mini

  remove: (selector, keepData) ->
    return super if keepData

    @trigger 'before-remove'
    @unsubscribeFromBuffer()
    rootView = @rootView()
    if @pane() then @pane().remove() else super
    rootView?.focus()

  unsubscribeFromBuffer: ->
    @buffer.off ".editor#{@id}"
    @renderer.destroy()

  stateForScreenRow: (row) ->
    @renderer.lineForRow(row).state

  getCurrentMode: ->
    @buffer.getMode()

  scrollTo: (pixelPosition) ->
    _.defer => # Optimization
      @scrollVertically(pixelPosition)
      @scrollHorizontally(pixelPosition)

  scrollVertically: (pixelPosition) ->
    linesInView = @scroller.height() / @lineHeight
    maxScrollMargin = Math.floor((linesInView - 1) / 2)
    scrollMargin = Math.min(@vScrollMargin, maxScrollMargin)
    margin = scrollMargin * @lineHeight
    desiredTop = pixelPosition.top - margin
    desiredBottom = pixelPosition.top + @lineHeight + margin

    if desiredBottom > @scroller.scrollBottom()
      @scroller.scrollBottom(desiredBottom)
    else if desiredTop < @scroller.scrollTop()
      @scroller.scrollTop(desiredTop)

  scrollHorizontally: (pixelPosition) ->
    return if @softWrap

    charsInView = @scroller.width() / @charWidth
    maxScrollMargin = Math.floor((charsInView - 1) / 2)
    scrollMargin = Math.min(@hScrollMargin, maxScrollMargin)
    margin = scrollMargin * @charWidth
    desiredRight = pixelPosition.left + @charWidth + margin
    desiredLeft = pixelPosition.left - margin

    if desiredRight > @scroller.scrollRight()
      @scroller.scrollRight(desiredRight)
    else if desiredLeft < @scroller.scrollLeft()
      @scroller.scrollLeft(desiredLeft)

  syncCursorAnimations: ->
    for cursor in @getCursors()
      do (cursor) -> cursor.resetCursorAnimation()

  logLines: ->
    @renderer.logLines()
