(function () {
  var input = document.getElementById("site-search");
  var panel = document.getElementById("search-results");
  if (!input || !panel) return;

  var posts = null;
  var loading = false;
  var results = [];
  var active = -1;

  function esc(value) {
    return String(value == null ? "" : value).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function load() {
    if (posts || loading) return;
    loading = true;
    fetch(input.dataset.index || "/index.json")
      .then(function (res) {
        if (!res.ok) throw new Error("HTTP " + res.status);
        return res.json();
      })
      .then(function (data) {
        posts = Array.isArray(data) ? data : [];
      })
      .catch(function () {
        posts = [];
      })
      .then(function () {
        loading = false;
        if (input.value.trim()) render(input.value);
      });
  }

  function close() {
    panel.classList.remove("open");
    panel.innerHTML = "";
    results = [];
    active = -1;
    input.setAttribute("aria-expanded", "false");
    input.removeAttribute("aria-activedescendant");
  }

  function setActive(index) {
    active = index;
    var links = panel.querySelectorAll("a");
    for (var i = 0; i < links.length; i++) {
      var isActive = i === active;
      links[i].classList.toggle("active", isActive);
      links[i].setAttribute("aria-selected", isActive ? "true" : "false");
      if (isActive) input.setAttribute("aria-activedescendant", links[i].id);
    }
  }

  function render(query) {
    var q = query.trim().toLowerCase();
    if (!q) {
      close();
      return;
    }
    if (!posts) {
      load();
      return;
    }

    results = posts
      .filter(function (post) {
        var haystack = [post.title, post.description, (post.tags || []).join(" "), post.text].join(" ").toLowerCase();
        return haystack.indexOf(q) !== -1;
      })
      .slice(0, 8);

    if (!results.length) {
      panel.innerHTML = '<div class="r-empty">No posts match &ldquo;' + esc(query) + '&rdquo;</div>';
      active = -1;
      input.removeAttribute("aria-activedescendant");
    } else {
      panel.innerHTML = results
        .map(function (post, i) {
          return (
            '<a href="' + esc(post.url) + '" id="search-opt-' + i + '" role="option" aria-selected="false">' +
            '<span class="r-title">' + esc(post.title) + "</span>" +
            '<span class="r-meta">' + esc(post.date) + " · " + esc((post.tags || []).join(", ")) + "</span>" +
            "</a>"
          );
        })
        .join("");
      setActive(0);
    }
    panel.classList.add("open");
    input.setAttribute("aria-expanded", "true");
  }

  function move(delta) {
    if (!results.length) return;
    setActive((active + delta + results.length) % results.length);
  }

  input.addEventListener("focus", load);
  input.addEventListener("input", function () {
    render(input.value);
  });

  input.addEventListener("keydown", function (event) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      move(1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      move(-1);
    } else if (event.key === "Enter") {
      if (active >= 0 && results[active]) {
        event.preventDefault();
        window.location.href = results[active].url;
      }
    } else if (event.key === "Escape") {
      input.value = "";
      close();
      input.blur();
    }
  });

  input.addEventListener("blur", function () {
    window.setTimeout(close, 150);
  });

  document.addEventListener("keydown", function (event) {
    var tag = (event.target.tagName || "").toLowerCase();
    if (event.key === "/" && tag !== "input" && tag !== "textarea") {
      event.preventDefault();
      input.focus();
    }
  });

  function syncUrl(value) {
    try {
      var url = new URL(window.location.href);
      if (value.trim()) url.searchParams.set("q", value);
      else url.searchParams.delete("q");
      window.history.replaceState(null, "", url);
    } catch (e) {}
  }

  input.addEventListener("input", function () {
    syncUrl(input.value);
  });

  try {
    var initial = new URLSearchParams(window.location.search).get("q");
    if (initial) {
      input.value = initial;
      load();
      render(initial);
    }
  } catch (e) {}
})();
