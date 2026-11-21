document.addEventListener("DOMContentLoaded", function () {
  document.querySelectorAll(".markdown-body pre").forEach(function (pre) {
    if (pre.parentElement && pre.parentElement.classList.contains("code-wrap")) return;

    var wrap = document.createElement("div");
    wrap.className = "code-wrap";
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(pre);

    var button = document.createElement("button");
    button.type = "button";
    button.className = "copy-btn";
    button.textContent = "Copy";
    button.setAttribute("aria-label", "Copy this code block");

    button.addEventListener("click", function () {
      var code = pre.innerText;
      var done = function () {
        button.textContent = "Copied";
        window.setTimeout(function () {
          button.textContent = "Copy";
        }, 1500);
      };

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(code).then(done, function () {});
      } else {
        var area = document.createElement("textarea");
        area.value = code;
        area.setAttribute("readonly", "");
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.appendChild(area);
        area.select();
        try {
          document.execCommand("copy");
          done();
        } catch (e) {}
        area.remove();
      }
    });

    wrap.appendChild(button);
  });

  function copyText(text, done) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {});
      return;
    }
    var area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand("copy");
      done();
    } catch (e) {}
    area.remove();
  }

  document.querySelectorAll(".share-btn").forEach(function (button) {
    button.addEventListener("click", function () {
      var url = button.dataset.shareUrl || window.location.href;
      var title = button.dataset.shareTitle || document.title;
      var label = button.textContent;

      if (navigator.share) {
        navigator.share({ title: title, url: url }).catch(function () {});
      } else {
        copyText(url, function () {
          button.textContent = "Link copied";
          window.setTimeout(function () {
            button.textContent = label;
          }, 1500);
        });
      }
    });
  });

  var toc = document.querySelector("details.toc");
  if (toc && window.matchMedia && window.matchMedia("(max-width: 768px)").matches) {
    toc.open = false;
  }

  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc-body a[href^='#']"));
  tocLinks.forEach(function (link) {
    link.addEventListener("click", function () {
      if (toc && window.matchMedia && window.matchMedia("(max-width: 768px)").matches) {
        toc.open = false;
      }
    });
  });
  if (tocLinks.length && "IntersectionObserver" in window) {
    var byHeading = new Map();
    tocLinks.forEach(function (link) {
      var heading = document.getElementById(decodeURIComponent(link.getAttribute("href").slice(1)));
      if (heading) byHeading.set(heading, link);
    });

    var clear = function () {
      tocLinks.forEach(function (link) {
        link.classList.remove("active");
        link.removeAttribute("aria-current");
      });
    };

    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          var link = byHeading.get(entry.target);
          if (!link) return;
          clear();
          link.classList.add("active");
          link.setAttribute("aria-current", "true");
        });
      },
      { rootMargin: "0px 0px -70% 0px", threshold: 0 }
    );

    byHeading.forEach(function (_, heading) {
      observer.observe(heading);
    });
  }
});
