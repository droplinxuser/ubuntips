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
});
