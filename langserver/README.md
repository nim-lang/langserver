# Nim Tortoise Language Server

## "Slow and steady wins the race"

A Language Server for `nim` that prioritises correctness over speed.  

A fork and rewrite of `nimlangserver`.  It aims to solve a number of problems when using the combination of `nimlangserver` and it's accompanying `VS Code` extension.

Earlier on in this project, I created pull requests of many of the improvements I made to `nimlangserver` to the main github repo, but after a while, I realized there were some architectural choices in the original that necessitated a major rewrite of its internals.  

The main problems with `nimlangserver` occur when it is used on large projects, especially monorepo projects containing a number of different nim packages.

In these situations you will frequently see:
- slow start-up times (on my project, it would take 1min 45s to get any highlighting in VS Code).
- Highlighting, mouseover and inlays break after 10-15mins of usage / jumping around a number of different files.
- Highlighting, mouseover etc. frequently show outdated information
- The max number of `nimsuggest` instances is not respected.

The aim of this fork is to: `be fast` and `be correct`.  

## Improvements

Upon examining the code base of `nimlangserver` and the `vscode-nim` extension, it became clear that most of the issues stemmed from a few key problems:

- When `nimble` is invoked it does not have the correct (or any) project information.  In later versions of `nimble`, this causes the built-in `SAT` solver to kick in and spend forever trying to find the nimble file of the project, starting from whichever folder it has been invoked from.  
- An inelegant separation between the VS Code extension and the Language Server.  In its current version, the VS Code extension is spinning up nimble instances (with incorrect project information) and also calling functions that should be in the domain of the main language server - this also becomes the site of a number of bugs and slow-downs.
- An uncontrolled use of async procedures throughout the code-base causing problems with race conditions.  This could cause crashes in the worse case, and incorrect responses in the best case.
- Mishandling of `nimsuggest` processes.  While it often looks like `nimsuggest` is the culprit of the problems with `nimlangserver` when looking at Task Manager or Activity Monitor, upon inspection, it seems that most of the problems are actually to do with how `nimlangserver` handles the different instances.  Often `nimsuggest` was sent incorrect or out-of-date information and, because it was being invoked from multiple places in the code base at different times, it could be either busy (leading to requests timing out), or crashing due to the fact that it had not initialized or was getting information about a file which no longer existed before it had received information the file had been deleted.  `nimsuggest` is, at its heart, a simple program - it loads the entirety of a nim project into memory and can then respond to queries about the project.  This means that the complexity of which files it handles and when needs to be carefully controlled by the language server.


# Changes

The major changes are a dispatcher and queue-based system to prevent the race conditions that were often the reason for crashes, timeouts or incorrect responses.  All language server requests go through a dispatcher, which then places the request into the queue of a `nimsuggest` instance.  These queues ensure each request is processed in order, preventing races.   

The Language Server is solely responsible for if and how a `nimsuggest` instance can spawn, be updated or be shutdown.  `nimsuggest` is invoked in a much smaller number of places, allowing better control over exactly what information is being sent and received and in which order.

Part of the change to the code has involved the removal of a number of async functions - replacing them with synchronous functions to hopefully allow better testing and remove additional complexity.  


Requires `nimble >= 0.16.1` and a `nimsuggest` that supports `--v3` (Nim 1.6+ or devel).

