/*
 * marc — DOM helpers: element construction, the icon set that stands in for the
 * SF Symbols used on macOS, and the context menu / popover / modal primitives
 * that replace NSMenu, SwiftUI .popover, and NSAlert.
 */
"use strict";

const UI = (() => {
  const SVG_NS = "http://www.w3.org/2000/svg";

  /* Icon paths are drawn on a 24x24 grid with a 1.6 stroke. */
  const ICONS = {
    folder: "M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z",
    doc: "M6 3h8l5 5v13H6zM14 3v5h5M9 12h7M9 16h7",
    split: "M4 5h16v14H4zM12 5v14",
    code: "M9 7l-5 5 5 5M15 7l5 5-5 5",
    sidebar: "M4 5h16v14H4zM9 5v14",
    graph: "M12 4v6M12 14v6M6 12H4M20 12h-2M12 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4M12 4a1.5 1.5 0 1 0 0-3M6.5 17.5a2 2 0 1 0-3 0M20.5 17.5a2 2 0 1 0-3 0",
    scope: "M12 3v3M12 18v3M3 12h3M18 12h3M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10M12 11.2a.8.8 0 1 0 0 1.6.8.8 0 0 0 0-1.6",
    search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14M16.5 16.5L21 21",
    palette: "M12 3a9 9 0 1 0 0 18c1.2 0 2-.8 2-1.8 0-.5-.2-.9-.5-1.2-.3-.3-.5-.7-.5-1.2 0-1 .8-1.8 1.8-1.8H16a5 5 0 0 0 5-5c0-3.9-4-7-9-7M7.5 12a1 1 0 1 0 0-.1M10 8a1 1 0 1 0 0-.1M14.5 8a1 1 0 1 0 0-.1M17.5 11.5a1 1 0 1 0 0-.1",
    groups: "M4 5h6v5H4zM14 5h6v5h-6zM4 14h6v5H4zM14 14h6v5h-6z",
    ellipsis: "M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18M8 12h.01M12 12h.01M16 12h.01",
    close: "M6 6l12 12M18 6L6 18",
    plus: "M12 5v14M5 12h14",
    chevronUp: "M6 15l6-6 6 6",
    chevronDown: "M6 9l6 6 6-6",
    chevronRight: "M9 6l6 6-6 6",
    chevronLeft: "M15 6l-6 6 6 6",
    warning: "M12 4l9 16H3zM12 10v4M12 17h.01",
    star: "M12 4l2.5 5.2 5.5.8-4 3.9 1 5.6-5-2.7-5 2.7 1-5.6-4-3.9 5.5-.8z",
    checkBubble: "M4 5h16v11H13l-4 4v-4H4zM8 10.5l2.5 2.5 5-5",
    outline: "M4 6h3M9 6h11M4 12h3M9 12h8M4 18h3M9 18h6",
    history: "M4 12a8 8 0 1 0 2.5-5.8M4 4v4h4M12 8v4.5l3 1.7",
    brain: "M9 4a3 3 0 0 0-3 3 3 3 0 0 0-1 5.8V16a3 3 0 0 0 3 3h1V4zM15 4a3 3 0 0 1 3 3 3 3 0 0 1 1 5.8V16a3 3 0 0 1-3 3h-1V4z",
    missing: "M12 3l9 9-9 9-9-9zM12 8.5c1.2 0 2 .8 2 1.8 0 1.4-2 1.4-2 3M12 16h.01",
    checkSquare: "M4 5h16v14H4zM8 12l2.5 2.5L16 9",
    square: "M4 5h16v14H4z",
    tap: "M9 11V6a1.5 1.5 0 0 1 3 0v7M12 10.5a1.5 1.5 0 0 1 3 0V13M15 11.5a1.5 1.5 0 0 1 3 0V16a5 5 0 0 1-5 5h-1.5a5 5 0 0 1-4.3-2.5L5 15l1-1a1.8 1.8 0 0 1 2.5.3l.5.7",
    noNetwork: "M4 4l16 16M5 9.5a13 13 0 0 1 4-2.4M15 7.1a13 13 0 0 1 4 2.4M8 13a8 8 0 0 1 2-1.2M14 11.8a8 8 0 0 1 2 1.2M12 17h.01",
    quote: "M6 15c-1.5 0-2.5-1-2.5-2.5S4.5 10 6 10c0-2 1-3.5 3-4M16 15c-1.5 0-2.5-1-2.5-2.5S14.5 10 16 10c0-2 1-3.5 3-4",
    check: "M5 12.5l4.5 4.5L19 7",
    save: "M5 4h11l3 3v13H5zM8 4v5h7V4M8 13h8v7H8z",
    revert: "M4 9h11a5 5 0 0 1 0 10h-6M4 9l4-4M4 9l4 4"
  };

  function icon(name, extraClass) {
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("class", extraClass === undefined ? "icon" : `icon ${extraClass}`);
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS(SVG_NS, "path");
    path.setAttribute("d", ICONS[name] ?? ICONS.doc);
    svg.append(path);
    return svg;
  }

  /**
   * Create an element.
   *
   * @param {string} tag  optionally "tag.class1.class2"
   * @param {object} [props] attributes; `text`, `html`, `dataset`, `style`,
   *   `on` (event map), and DOM properties are handled specially
   * @param {Array} [children]
   */
  function el(tag, props, children) {
    const [name, ...classes] = tag.split(".");
    const node = document.createElement(name);
    if (classes.length > 0) node.className = classes.join(" ");

    if (props !== null && props !== undefined) {
      for (const [key, value] of Object.entries(props)) {
        if (value === null || value === undefined || value === false) continue;
        if (key === "text") node.textContent = value;
        else if (key === "html") node.innerHTML = value;
        else if (key === "class") node.className = `${node.className} ${value}`.trim();
        else if (key === "style") Object.assign(node.style, value);
        else if (key === "dataset") Object.assign(node.dataset, value);
        else if (key === "on") {
          for (const [event, handler] of Object.entries(value)) node.addEventListener(event, handler);
        } else if (key in node && key !== "title" && key !== "type") {
          node[key] = value;
        } else {
          node.setAttribute(key, value === true ? "" : value);
        }
      }
    }

    if (children !== null && children !== undefined) {
      for (const child of children.flat === undefined ? [children] : children.flat(4)) {
        if (child === null || child === undefined || child === false) continue;
        node.append(typeof child === "string" || typeof child === "number" ? String(child) : child);
      }
    }
    return node;
  }

  function clear(node) {
    while (node.firstChild !== null) node.firstChild.remove();
    return node;
  }

  /* ------------------------------------------------------ layered surfaces */

  let dismissLayer = null;

  function dismissAll() {
    if (dismissLayer !== null) {
      dismissLayer.cleanup();
      dismissLayer = null;
    }
  }

  function present(node, host, onDismiss) {
    dismissAll();
    const overlay = el("div.overlay");
    const target = document.getElementById(host);
    overlay.addEventListener("mousedown", (event) => {
      event.preventDefault();
      dismissAll();
    });
    overlay.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      dismissAll();
    });
    target.append(overlay, node);

    const onKey = (event) => {
      if (event.key === "Escape") {
        event.stopPropagation();
        dismissAll();
      }
    };
    document.addEventListener("keydown", onKey, true);

    dismissLayer = {
      cleanup: () => {
        document.removeEventListener("keydown", onKey, true);
        overlay.remove();
        node.remove();
        if (typeof onDismiss === "function") onDismiss();
      }
    };
    return dismissLayer;
  }

  /** Keep a floating surface inside the window. */
  function positionFloating(node, anchorRect, preferredAlign) {
    const margin = 8;
    const rect = node.getBoundingClientRect();
    let left =
      preferredAlign === "right"
        ? anchorRect.right - rect.width
        : anchorRect.left;
    let top = anchorRect.bottom + 4;

    left = Math.max(margin, Math.min(left, window.innerWidth - rect.width - margin));
    if (top + rect.height > window.innerHeight - margin) {
      top = Math.max(margin, anchorRect.top - rect.height - 4);
    }
    node.style.left = `${Math.round(left)}px`;
    node.style.top = `${Math.round(top)}px`;
  }

  /**
   * Show a context menu.
   *
   * @param {Array} items  {label, action, disabled, destructive, checked,
   *   separator, note, submenu}
   */
  function menu(items, anchor, align) {
    const node = el("div.context-menu");
    for (const item of items) {
      if (item === null || item === undefined || item === false) continue;
      if (item.separator === true) {
        node.append(el("div.separator"));
        continue;
      }
      if (item.note !== undefined) {
        node.append(el("div.note", { text: item.note }));
        continue;
      }
      const button = el(
        "button",
        {
          disabled: item.disabled === true,
          class: item.destructive === true ? "destructive" : "",
          on: {
            click: () => {
              if (item.disabled === true) return;
              if (Array.isArray(item.submenu)) {
                const rect = button.getBoundingClientRect();
                menu(item.submenu, rect, align);
                return;
              }
              dismissAll();
              if (typeof item.action === "function") item.action();
            }
          }
        },
        [
          item.checked === true ? icon("check") : el("span", { style: { width: "16px", flex: "none" } }),
          el("span", { text: item.label }),
          Array.isArray(item.submenu) ? el("span", { style: { marginLeft: "auto" }, text: "›" }) : null
        ]
      );
      node.append(button);
    }

    present(node, "menu-host");
    const rect =
      anchor instanceof Element ? anchor.getBoundingClientRect() : anchor;
    positionFloating(node, rect, align);
    return node;
  }

  function contextMenuAt(items, event) {
    event.preventDefault();
    event.stopPropagation();
    const point = {
      left: event.clientX,
      right: event.clientX,
      top: event.clientY,
      bottom: event.clientY
    };
    menu(items, point);
  }

  function popover(content, anchor, options) {
    const settings = options ?? {};
    const node = el("div.popover", {
      style: { width: `${settings.width ?? 340}px` }
    }, [content]);
    present(node, "popover-host", settings.onDismiss);
    positionFloating(node, anchor.getBoundingClientRect(), settings.align ?? "right");
    return node;
  }

  function isPopoverOpen() {
    return document.querySelector("#popover-host .popover") !== null;
  }

  /** Modal dialog. Resolves with the value passed to `close`. */
  function modal(build) {
    return new Promise((resolve) => {
      const backdrop = el("div.modal-backdrop");
      const close = (value) => {
        backdrop.remove();
        document.removeEventListener("keydown", onKey, true);
        resolve(value);
      };
      const onKey = (event) => {
        if (event.key === "Escape") {
          event.stopPropagation();
          close(null);
        }
      };
      const panel = build(close);
      backdrop.append(panel);
      backdrop.addEventListener("mousedown", (event) => {
        if (event.target === backdrop) close(null);
      });
      document.addEventListener("keydown", onKey, true);
      document.getElementById("modal-host").append(backdrop);
      const focusable = panel.querySelector("input, button");
      if (focusable !== null) focusable.focus();
      if (focusable instanceof HTMLInputElement) focusable.select();
    });
  }

  let toastTimer = null;

  function toast(message) {
    const existing = document.querySelector(".toast");
    if (existing !== null) existing.remove();
    if (toastTimer !== null) clearTimeout(toastTimer);
    const node = el("div.toast", { text: message });
    document.body.append(node);
    toastTimer = setTimeout(() => node.remove(), 3200);
  }

  function badge(count, color, opacity) {
    return el("span.count-badge", {
      text: String(count),
      style: {
        color,
        background: `color-mix(in srgb, ${color} 15%, transparent)`,
        opacity: opacity === undefined ? "1" : String(opacity)
      }
    });
  }

  return {
    el,
    icon,
    clear,
    menu,
    contextMenuAt,
    popover,
    isPopoverOpen,
    modal,
    toast,
    badge,
    dismissAll,
    positionFloating
  };
})();
