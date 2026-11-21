(function () {
  var root = document.documentElement;
  var stored = null;
  try {
    stored = localStorage.getItem("theme");
  } catch (e) {}
  if (stored === "light" || stored === "dark") root.dataset.theme = stored;

  function effective() {
    if (root.dataset.theme === "light" || root.dataset.theme === "dark") return root.dataset.theme;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function paint(button) {
    var next = effective() === "dark" ? "light" : "dark";
    button.dataset.next = next;
    button.setAttribute("aria-label", "Switch to " + next + " theme");
    button.setAttribute("title", "Switch to " + next + " theme");
    var sun = button.querySelector(".icon-sun");
    var moon = button.querySelector(".icon-moon");
    if (sun) sun.hidden = effective() !== "dark";
    if (moon) moon.hidden = effective() === "dark";
  }

  document.addEventListener("DOMContentLoaded", function () {
    var button = document.getElementById("theme-toggle");
    if (!button) return;
    paint(button);
    button.addEventListener("click", function () {
      root.dataset.theme = button.dataset.next;
      try {
        localStorage.setItem("theme", button.dataset.next);
      } catch (e) {}
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
