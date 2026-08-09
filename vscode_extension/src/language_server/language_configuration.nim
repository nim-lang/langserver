import ../platform/vscodeApi
import ../platform/js/jsre
import ../platform/js/jsString

proc initNimLanguageConfiguration*(): VscodeLanguageConfiguration =
  ## This sets up VSCode's editor behaviour for Nim files — specifically what happens when you press Enter, and how the editor identifies "words".
  ## onEnterRules — four rules, checked top-to-bottom against the line you're pressing Enter on:
  ## ^(\s)*##  → line starts with ## (doc comment). Appends ##  on the next line so you can keep typing the doc comment without retyping the prefix.
  ## case ... : → a case statement header. No indent change — because case branches use of at the same level, not a deeper indent.
  ## proc/macro/type/import/something: etc. → any line that opens a new block. Indents the next line in.
  ## return/raise/break/continue → a terminating statement. Outdents the next line, since whatever follows logically belongs at a shallower level.
  ## wordPattern — tells VSCode what counts as a "word" for double-click selection, Ctrl+D, etc. The two alternatives are:
  ## A number literal (e.g. -3.14)
  ## Any sequence of characters that isn't punctuation or whitespace — which covers Nim identifiers including ones with backtick-quoting stripped out
  # This is pure editor configuration — nothing to do with the language server.
  return VscodeLanguageConfiguration{
    # @Note Literal whitespace in below regexps is removed
    onEnterRules: newArrayWith[VscodeOnEnterRule](
      VscodeOnEnterRule{
        # Was: r"^(\s)*## " — (\s)* wraps a single \s in an unnecessary capture group;
        # \s* is equivalent and cleaner.
        beforeText: newRegExp(r"^\s*## ", ""),
        action:
          VscodeEnterAction{indentAction: VscodeIndentAction.none, appendText: "## "},
      },
      VscodeOnEnterRule{
        beforeText: newRegExp(
          """
          ^\s*
          ( (case) \b .* :? )
          \s*$
          """.replace(
            # Was: newRegExp(r"\s+?", r"g") — lazy quantifier is unnecessary here;
            # since this is a global replace, \s+ and \s+? produce the same result
            # (all whitespace removed), but \s+ is clearer about the intent.
            newRegExp(r"\s+", r"g"), ""
          ),
          "",
        ),
        # Was: case \b .* : (required a trailing colon). Modern Nim style omits the
        # colon after the case expression (e.g. `case x` not `case x:`), so the rule
        # never fired for idiomatic code. Changed .* : to .*:? to make the colon optional.
        action: VscodeEnterAction{indentAction: VscodeIndentAction.none},
      },
      VscodeOnEnterRule{
        beforeText: newRegExp(
          """
          ^\s*
          (
            ((proc|macro|iterator|template|converter|func) \b .*=) |
            ((import|export|let|var|const|type) \b) |
            ([^:]+:)
          )
          \s*$
          """.replace(
            # Was: newRegExp(r"\s+?", r"g") — see note above on lazy quantifier.
            newRegExp(r"\s+", r"g"), ""
          ),
          "",
        ),
        action: VscodeEnterAction{indentAction: VscodeIndentAction.indent},
      },
      VscodeOnEnterRule{
        beforeText: newRegExp(
          """
          ^\s*
          (
            ((return|raise|break|continue) \b .*)
          )
          \s*
          """.replace(
            # Was: newRegExp(r"\s+?", r"g") — see note above on lazy quantifier.
            newRegExp(r"\s+", r"g"), ""
          ),
          "",
        ),
        # Was: also matched `(discard)\b` as a second alternative and outdented after it.
        # discard is not a block terminator — it discards the value of an expression and
        # can appear anywhere in a function body. Outdenting after `discard foo()` would
        # move the cursor back a level on every Enter, which is wrong in the common case.
        # return/raise/break/continue are genuine exits from the current scope, so
        # outdenting after them makes sense; discard is not in that category.
        action: VscodeEnterAction{indentAction: VscodeIndentAction.outdent},
      },
    ),
    wordPattern: newRegExp(
      r"(-?\d*\.\d\w*)|([^\`\~\!\@\#\%\^\&\*\(\)\-\=\+\[\{\]\}\\\|\;\:\'\""\,\.\<\>\/\?\s]+)",
      r"g",
    ),
  }
