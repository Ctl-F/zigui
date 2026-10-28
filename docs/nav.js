// The sidebar. Adding a page to the docs means adding one line here.
// Paths are relative to docs/; pages in docs/widgets/ set data-root="../".
(function () {
  var root = document.body.getAttribute("data-root") || "";
  var sections = [
    ["Start", [
      ["index.html", "Overview"],
      ["getting-started.html", "Getting started"],
      ["how-it-works.html", "How it works"],
      ["layout.html", "Layout and styling"],
      ["events.html", "Events, commands, shortcuts"],
      ["theming.html", "Theming"],
    ]],
    ["Widgets", [
      ["widgets/index.html", "Widget overview"],
      ["widgets/container.html", "Containers (box)"],
      ["widgets/label.html", "Label"],
      ["widgets/button.html", "Button"],
      ["widgets/text-field.html", "TextField"],
      ["widgets/code-editor.html", "CodeEditor"],
      ["widgets/canvas.html", "Canvas"],
      ["widgets/scroll-view.html", "ScrollView"],
      ["widgets/split-view.html", "SplitView"],
      ["widgets/tree-view.html", "TreeView"],
      ["widgets/select.html", "Select"],
      ["widgets/menus.html", "Menus and MenuBar"],
    ]],
    ["Tools", [
      ["documents.html", "UI documents (ZON)"],
      ["builder.html", "The builder"],
      ["forms.html", "Forms and wizards"],
      ["testing.html", "Testing and debugging"],
    ]],
    ["Project", [
      ["maintaining.html", "Maintaining these docs"],
    ]],
  ];
  var here = location.pathname.split("/docs/").pop();
  var html = '<a href="' + root + 'index.html"><b>zigui docs</b></a>';
  sections.forEach(function (s) {
    html += "<h2>" + s[0] + "</h2>";
    s[1].forEach(function (p) {
      html += '<a href="' + root + p[0] + '"' + (here === p[0] ? ' class="here"' : "") + ">" + p[1] + "</a>";
    });
  });
  var nav = document.getElementById("nav");
  if (nav) nav.innerHTML = html;
})();
