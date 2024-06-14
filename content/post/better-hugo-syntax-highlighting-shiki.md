---
author: "Bojan Zivanovic"
date: 2024-06-14
title: Better Hugo syntax highlighting with Shiki
slug: "better-hugo-syntax-highlighting-shiki"
---

Every blog deserves truly great syntax highlighting.

Out of the box, [Hugo](https://gohugo.io/) performs syntax highlighting at build time, converting Markdown code blocks into precolored HTML.
This is done quickly enough to be unnoticeable, and the output can be restyled by [regenerating the provided CSS file](https://gohugo.io/content-management/syntax-highlighting/#generate-syntax-highlighter-css). 

Some Hugo themes opt to use [Highlight.js](https://highlightjs.org/) instead, a more battle-tested client-side solution which performs highlighting on each page load.

Unfortunately, in both cases the results can be spotty, with portions of the source code left uncolored. As always, your mileage may vary, but if you're
reading this post, you probably have a similar impression. My goal is ambitious: I want highlighted code to look the same as in my editor, VS Code. 
I can do what some developers do and simply [generate screenshots](https://marketplace.visualstudio.com/items?itemName=adpyke.codesnap) of the code but that's obviously non-optimal.

My preferred alternative is [Shiki](https://shiki.style/):

> Shiki is a syntax highlighter that uses TextMate grammars and themes, the same engine that powers VS Code. It provides one of the most accurate and beautiful syntax highlighting for your code snippets. It was created by Pine Wu back in 2018, when he was part of the VS Code team. Different from existing syntax highlighters like Prism and Highlight.js that designed to run in the browser, Shiki took a different approach by highlighting ahead of time. It ships the highlighted HTML to the client, producing accurate and beautiful syntax highlighting with zero JavaScript. It soon took off and became a very popular choice, especially for static site generators and documentation sites.

Is it truly great? This blog is now fully powered by it, so decide for yourself! 

I've found no existing resources describing how to use Hugo and Shiki together, so here are my setup notes, in hopes that they will be useful to someone. 

Let's start by disabling Hugo's built-in syntax highlighting. Append this to your `config.toml`:
```toml
[markup]
  [markup.highlight]
    codeFences = false
```

Shiki is just a library, so in order to run it, we need [Rehype](https://github.com/rehypejs/rehype), a CLI which can process HTML files. 

Install Shiki and Rehype in the root of your site:
```sh
npm install @shikijs/rehype
npm install rehype-cli
```

And then create a `.rehyperc` file:
```js
{
  "plugins": [
    ["@shikijs/rehype", {"theme": "light-plus"}]
  ]
}
```

We can now run `npx rehype-cli public -o` to highlight all of our pages. Ideally there would be a way for Hugo to run that command automatically at the end
of the build process, but since there isn't, we can just run both commands ourselves.

Let's create a `Makefile`:
```make
.DEFAULT_GOAL := build

.PHONY: build
build:
	hugo
	npx rehype-cli public -o
```

The full build can now be done by a single `make`. It takes about 7s on my machine, a far cry from Hugo's initial 20ms, but I've found that to be a price worth paying. While editing, I still rely on `hugo serve`, performing the full build only once I am done.
