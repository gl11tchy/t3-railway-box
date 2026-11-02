// Adds "where do I get a code?" to T3's pairing screen, which otherwise never says.
(() => {
  const ID = "railway-pair-hint";
  const add = () => {
    if (document.getElementById(ID)) return;
    const heading = [...document.querySelectorAll("h1,h2,h3,div,p")].find(
      (el) => el.childElementCount === 0 && el.textContent.trim() === "Pair with this environment",
    );
    if (!heading) return;
    const card = heading.closest("section") ?? heading.parentElement;
    const note = document.createElement("div");
    note.id = ID;
    note.style.cssText =
      "margin-top:16px;padding:12px 16px;border:1px solid rgba(127,127,127,.35);border-radius:10px;font-size:14px;line-height:1.5";
    note.innerHTML =
      "<b>No code?</b> Open <a href=\"/railway-pair\" style=\"text-decoration:underline\">/railway-pair</a> and sign in " +
      "with any username and the setup password. The password is in Railway: project <b>t3-cloud-agents</b> &rarr; " +
      "<b>T3 Code</b> &rarr; <b>Variables</b> &rarr; <b>T3_SETUP_PASSWORD</b>. " +
      "Or, on a device that is already connected, open Settings &rarr; Sharing &amp; access &rarr; Create link and scan the QR code.";
    card.appendChild(note);
  };
  new MutationObserver(add).observe(document.documentElement, { childList: true, subtree: true });
  add();
})();
