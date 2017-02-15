(function() {
  var DEBUG_SCROLLING = location.href.match(/debug=\w*,?\bscroll\b/);
  var THRESHOLD = 60;

  Convos.mixin.messages = {
    watch: {
      "dialog.active": function(v, o) {
        if (v === false && this.scrollPosTid) clearTimeout(this.scrollPosTid);
        if (v === true) this.scrollPosTid = setInterval(this.keepScrollPos, 200);
      }
    },
    methods: {
      onScroll: function(e) {
        if (DEBUG_SCROLLING) console.log("[onScroll:" + this.dialog.dialog_id + "]", this.atBottom, this.scrollEl.scrollTop, this.scrollEl.scrollHeight - this.scrollEl.offsetHeight, this.scrollTid);
        if (this.scrollTid == "skip") return this.scrollTid = undefined;
        if (!this.scrollTid) this.scrollTid = setTimeout(this.onScrollDelayed, 250);
      },
      onScrollDelayed: function() {
        var self = this;
        var el = this.scrollEl;
        var messages = this.$refs.messages;
        var innerHeight = window.innerHeight || document.documentElement.clientHeight;
        var scrollHeight = el.scrollHeight;
        var scrollTop = el.scrollTop;

        this.atBottom = scrollHeight - el.offsetHeight < scrollTop + THRESHOLD;

        for (var i = 0; i < messages.length; i++) {
          var offsetTop = messages[i].$el.offsetTop;
          if (offsetTop > scrollTop + innerHeight) break;
          if (offsetTop < scrollTop) continue;
          messages[i].$emit("visible");
        }

        if (scrollTop > THRESHOLD) {
          return this.scrollTid = undefined;
        }
        else {
          this.dialog.load({historic: true}, function(err, body) {
            self.$nextTick(function() {
              self.scrollTid = "skip";
              el.scrollTop = scrollTop + el.scrollHeight - scrollHeight;
            });
          });
        }
      },
      keepScrollPos: function() {
        if (this.atBottom && !this.scrollTid) this.scrollEl.scrollTop = this.scrollEl.scrollHeight;
      }
    },
    ready: function() {
      this.atBottom = true;
      this.scrollPos = 0;
      this.scrollEl = this.$el.querySelector(".scroll-element");
      this.scrollEl.addEventListener("scroll", this.onScroll);
      this.dialog.on("message", function() { this.$nextTick(this.keepScrollPos); }.bind(this));
    },
    beforeDestroy: function() {
      this.scrollEl.removeEventListener("scroll", this.onScroll);
    }
  };
})();