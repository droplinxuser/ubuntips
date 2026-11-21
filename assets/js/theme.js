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

  function isDark() {
    if (current() === "dark") return true;
    if (current() === "light") return false;
    return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
  }

  var themeColor = document.getElementById("theme-color");
  function syncThemeColor() {
    if (!themeColor) return;
    themeColor.setAttribute("content", isDark() ? themeColor.dataset.dark : themeColor.dataset.light);
  }
  syncThemeColor();

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
      syncThemeColor();
    });

    if (window.matchMedia) {
      var query = window.matchMedia("(prefers-color-scheme: dark)");
      if (query.addEventListener) {
        query.addEventListener("change", function () {
          if (!root.dataset.theme) {
            paint(button);
            syncThemeColor();
          }
        });
      }
    }
  });
})();
