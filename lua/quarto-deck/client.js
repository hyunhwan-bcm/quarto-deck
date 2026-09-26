// quarto-deck sync client. Injected into the rendered deck by the nvim plugin.
// Slides are addressed by their position in Reveal.getSlides(), which is the
// same order the plugin's parser produces from the .qmd source.
(function () {
  if (window.__quartoDeck) return;
  window.__quartoDeck = true;

  var BASE = "/__quarto_deck";
  // While we navigate on nvim's request, don't echo slide changes back: not
  // the target, and not slides passed on the way (scroll view).
  var applying = -1;
  var applyingUntil = 0;

  // Real slides only. Reveal 5's scroll view (auto-enabled on narrow
  // viewports, e.g. a terminal-browser pane) moves slides into wrappers and
  // leaves the emptied stack <section>s behind, which getSlides() counts.
  function slides() {
    return Reveal.getSlides().filter(function (s) {
      return s.id === "title-slide" || s.classList.contains("slide");
    });
  }

  function currentIndex() {
    return slides().indexOf(Reveal.getCurrentSlide());
  }

  function post(msg) {
    try {
      fetch(BASE + "/event", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(msg),
        keepalive: true,
      }).catch(function () {});
    } catch (e) {}
  }

  function go(index) {
    var list = slides();
    if (!list.length) return;
    index = Math.max(0, Math.min(index, list.length - 1));
    if (index === currentIndex()) return;
    applying = index;
    applyingUntil = Date.now() + 500;
    // Reveal 5's scroll view maps h/v wrongly inside vertical stacks
    // (slide(2,1) lands on 2/0), so scroll straight to the slide's page.
    if (Reveal.isScrollView && Reveal.isScrollView()) {
      var page = list[index].closest(".scroll-page");
      var viewport = document.querySelector(".reveal-viewport");
      if (page && viewport) {
        viewport.scrollTop = page.offsetTop;
        return;
      }
    }
    var target = Reveal.getIndices(list[index]);
    Reveal.slide(target.h, target.v);
  }

  function start() {
    post({ type: "hello", count: slides().length, index: currentIndex() });

    Reveal.on("slidechanged", function () {
      var index = currentIndex();
      if (applying !== -1) {
        if (index === applying || Date.now() < applyingUntil) {
          if (index === applying) applying = -1;
          return;
        }
        applying = -1;
      }
      if (index !== -1) post({ type: "slide", index: index });
    });

    var source = new EventSource(BASE + "/events");
    source.onmessage = function (e) {
      var msg;
      try {
        msg = JSON.parse(e.data);
      } catch (err) {
        return;
      }
      if (msg.type === "goto") go(msg.index);
      else if (msg.type === "reload") location.reload();
    };
  }

  function waitForReveal() {
    if (window.Reveal && typeof Reveal.isReady === "function") {
      if (Reveal.isReady()) start();
      else Reveal.on("ready", start);
    } else {
      setTimeout(waitForReveal, 50);
    }
  }

  waitForReveal();
})();
