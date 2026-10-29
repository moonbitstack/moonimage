// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0
//
// The theme switch: an aperture in the corner of the navigation.
//
// Wide open is daylight, stopped down is the darkroom. The button is built here
// rather than written into three pages, because a control that needs this file
// to work anyway may as well be the only copy of itself.
//
// A choice is remembered; without one the page follows the system, and keeps
// following it if the system changes while the page is open.

const KEY = "moonimage-theme";
const QUERY = window.matchMedia("(prefers-color-scheme: dark)");

/// What the page should be showing, stored choice first.
function preferred() {
  try {
    const stored = localStorage.getItem(KEY);
    if (stored === "light" || stored === "dark") {
      return stored;
    }
  } catch {
    // A browser with storage turned off still gets a working switch.
  }
  return QUERY.matches ? "dark" : "light";
}

function apply(theme) {
  document.documentElement.dataset.theme = theme;
  for (const button of document.querySelectorAll("[data-theme-toggle]")) {
    const dark = theme === "dark";
    button.setAttribute("aria-pressed", String(dark));
    button.setAttribute("aria-label", dark ? "Switch to daylight" : "Switch to the darkroom");
    button.title = dark ? "Daylight" : "Darkroom";
  }
}

/// The icon: an aperture, wide open by day and stopped down at night.
///
/// A disc with a hexagonal hole knocked out of it, which is what an iris looks
/// like from the front: the blades are the solid part and the opening is the
/// paper showing through. At twenty-one pixels a filled shape with a hole reads
/// better than drawn blades, and the size of the hole is the state.
function icon() {
  return `
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <circle class="ring" cx="12" cy="12" r="9.6"/>
      <g class="open">
        <path class="iris" fill-rule="evenodd" d="M12 3.20 A8.80 8.80 0 1 0 12 20.80 A8.80 8.80 0 1 0 12 3.20 Z M16.90 12.00 L14.45 16.24 L9.55 16.24 L7.10 12.00 L9.55 7.76 L14.45 7.76 Z"/>
      </g>
      <g class="closed">
        <path class="iris" fill-rule="evenodd" d="M12 3.20 A8.80 8.80 0 1 0 12 20.80 A8.80 8.80 0 1 0 12 3.20 Z M13.50 12.00 L12.75 13.30 L11.25 13.30 L10.50 12.00 L11.25 10.70 L12.75 10.70 Z"/>
      </g>
    </svg>`;
}

function install() {
  const nav = document.querySelector(".top nav");
  if (!nav) {
    return;
  }
  const button = document.createElement("button");
  button.type = "button";
  button.className = "aperture-toggle";
  button.dataset.themeToggle = "";
  button.innerHTML = icon();

  // Before the repository mark, which is the last thing in the bar.
  const mark = nav.querySelector(".icon-link");
  nav.insertBefore(button, mark || null);

  button.addEventListener("click", () => {
    const next = document.documentElement.dataset.theme === "dark" ? "light" : "dark";
    apply(next);
    try {
      localStorage.setItem(KEY, next);
    } catch {
      // Not being able to remember the choice is not a reason to refuse it.
    }
  });

  apply(preferred());
}

install();

// The scroll bar retracts while the page is at the top: a title page does not
// need a bar down its side, and it comes back the moment there is something to
// scroll to.
const root = document.documentElement;
function watchTop() {
  const sync = () => root.classList.toggle("at-top", window.scrollY <= 0);
  sync();
  window.addEventListener("scroll", sync, { passive: true });
}

watchTop();

// With no stored choice, a change in the system preference is followed live.
QUERY.addEventListener("change", () => {
  try {
    if (localStorage.getItem(KEY) === null) {
      apply(QUERY.matches ? "dark" : "light");
    }
  } catch {
    apply(QUERY.matches ? "dark" : "light");
  }
});
