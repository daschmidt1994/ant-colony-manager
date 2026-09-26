// Scan landing (/c/<token>): offer to open the Android app if the server
// provided an intent link. The page itself never shows colony data.
(function () {
  var intent = document.querySelector('meta[name="acm-app-intent"]').content;
  if (location.pathname.indexOf('/c/') === 0) {
    document.getElementById('status').textContent =
      'Kolonie-Code erkannt. Öffne ihn in der App oder melde dich in der Web-App an.';
    if (intent && intent.indexOf('intent://') === 0) {
      var a = document.getElementById('open-app');
      a.href = intent;
      a.hidden = false;
    }
  }
})();
