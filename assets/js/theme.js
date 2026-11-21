(function () {
  var root = document.documentElement;
  var stored = null;
  try {
    stored = localStorage.getItem("theme");
  } catch (e) {}
  if (stored === "light" || stored === "dark") root.dataset.theme = stored;

  function current() {
    if (root.dataset.theme === "light" || root.dataset.theme === "dark") return root.dataset.theme;
    return "system";
  }

  function nextOf(state) {
    return state === "system" ? "light" : state === "light" ? "dark" : "system";
  }

  function paint(button) {
    var next = nextOf(current());
    button.dataset.next = next;
    button.setAttribute("aria-label", "Switch to " + next + " theme");
    button.setAttribute("title", "Theme: " + current() + " (click for " + next + ")");
  }

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.getElementById("theme-toggle");
    if (!button) return;
    paint(button);

    button.addEventListener("click", function () {
      var next = button.dataset.next;
      if (next === "system") {
        delete root.dataset.theme;
        try {
          localStorage.removeItem("theme");
        } catch (e) {}
      } else {
        root.dataset.theme = next;
        try {
          localStorage.setItem("theme", next);
        } catch (e) {}
      }
      paint(button);
    });

    if (window.matchMedia) {
      var query = window.matchMedia("(prefers-color-scheme: dark)");
      if (query.addEventListener) {
        query.addEventListener("change", function () {
          if (!root.dataset.theme) paint(button);
        });
      }
    }
  });
})();
