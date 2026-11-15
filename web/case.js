// ============================================================================
// Racing Case: the opening reel
//
// Lua sends { action: 'case', data: { reel, win, seconds } }. The reel already ends on the
// prize the server gave (server/cases.lua): this only animates it, so nothing here can change
// what was won. Self-contained: its own listener, its own root, styled by case.css.
// ============================================================================
(() => {
    'use strict';

    const RESOURCE = window.GetParentResourceName ? GetParentResourceName() : 'whip-racing';
    // In game: https://cfx-nui-<resource>/<path>. In a browser preview (no game): /nui/<resource>/<path>.
    const nui = (res, path) => (window.invokeNative ? `https://cfx-nui-${res}/${path}` : `/nui/${res}/${path}`);

    // Where item pictures live: whip_core's own, then WHIP's other resources, each at
    // html/img/items/<key>.webp|png. The first that loads is remembered per item.
    const ITEM_HOMES = ['whip_core', 'whip_autos', 'whip_gunny', 'whip_fuel', 'whip_rope', 'whip_phone', 'whip_voice'];
    const SPECIAL = {
        cash: nui('whip_core', 'html/img/items/cash_3_stack.webp'),
        racing_case: nui(RESOURCE, 'racing_case.png'),
    };
    const found = new Map();   // item -> url that loaded ('' = none did)

    function candidates(tile) {
        const out = [];
        if (tile.image) {
            const m = /^@([^/]+)\/(.+)$/.exec(tile.image);
            out.push(m ? nui(m[1].toLowerCase(), m[2]) : tile.image);
        }
        if (SPECIAL[tile.item]) out.push(SPECIAL[tile.item]);
        for (const res of ITEM_HOMES) {
            out.push(nui(res, `html/img/items/${tile.item}.webp`));
            out.push(nui(res, `html/img/items/${tile.item}.png`));
        }
        return out;
    }

    /** An <img> that walks the candidate list until one loads; none, and it hides itself. */
    function picture(tile) {
        const img = document.createElement('img');
        img.alt = '';
        img.draggable = false;
        const known = found.get(tile.item);
        if (known === '') { img.className = 'none'; return img; }
        if (known) { img.src = known; return img; }

        const list = candidates(tile);
        let i = 0;
        img.onerror = () => {
            i += 1;
            if (i < list.length) img.src = list[i];
            else { found.set(tile.item, ''); img.className = 'none'; }
        };
        img.onload = () => { if (!found.has(tile.item)) found.set(tile.item, img.src); };
        img.src = list[0];
        return img;
    }

    function el(tag, cls, text) {
        const e = document.createElement(tag);
        if (cls) e.className = cls;
        if (text != null) e.textContent = text;
        return e;
    }

    let root = null;
    let timers = [];

    function clear() {
        timers.forEach(clearTimeout);
        timers = [];
        if (root) { root.remove(); root = null; }
    }

    function play(data) {
        clear();
        const reel = Array.isArray(data.reel) ? data.reel : [];
        const win = Math.max(1, Math.min(reel.length, Number(data.win) || 1));
        const seconds = Math.max(3, Math.min(12, Number(data.seconds) || 6));
        if (!reel.length) return;

        root = el('div', 'rc');
        const panel = el('div', 'rc-panel');
        const head = el('div', 'rc-head');
        head.append(el('small', '', 'WHIP Racing'), el('h2', '', 'Racing Case'));

        const windowEl = el('div', 'rc-window');
        const strip = el('div', 'rc-strip');
        reel.forEach((t, i) => {
            const cell = el('div', `rc-tile r-${t.rarity || 'common'}`);
            cell.append(picture(t), el('b', '', t.label || t.item));
            if (i + 1 === win && t.amountText) cell.append(el('span', 'amt', t.amountText));
            strip.append(cell);
        });
        windowEl.append(strip, el('i', 'rc-marker'));

        const result = el('div', 'rc-result');
        panel.append(head, windowEl, result);
        root.append(panel);
        document.body.append(root);

        // Land the prize under the marker, a little off centre so it doesn't look rigged-straight,
        // never off its own tile. Measured from the prize tile itself (its offsetLeft in the window,
        // strip padding and gaps included), after forcing layout now: no animation-frame wait,
        // which never comes while the page isn't being painted.
        const prizeEl = strip.children[win - 1];
        void strip.offsetWidth;   // layout, so the start position (no transform) is committed
        const jitter = (Math.random() - 0.5) * prizeEl.offsetWidth * 0.6;
        const target = prizeEl.offsetLeft + prizeEl.offsetWidth / 2 - windowEl.clientWidth / 2 + jitter;
        strip.style.transition = `transform ${seconds}s cubic-bezier(0.12, 0.72, 0.16, 1)`;
        strip.style.transform = `translateX(${-target}px)`;

        // The reveal, then out.
        timers.push(setTimeout(() => {
            const prize = reel[win - 1] || {};
            strip.children[win - 1].classList.add('won');
            result.className = `rc-result show r-${prize.rarity || 'common'}`;
            result.append(
                el('small', '', 'You won'),
                el('b', '', [prize.amountText, prize.label || prize.item].filter(Boolean).join(' ')),
                el('span', 'rar', (prize.rarity || 'common').replace(/^./, (c) => c.toUpperCase())),
            );
        }, seconds * 1000 + 150));
        timers.push(setTimeout(() => { if (root) root.classList.add('out'); }, seconds * 1000 + 3200));
        timers.push(setTimeout(clear, seconds * 1000 + 3600));
    }

    window.addEventListener('message', (event) => {
        const p = event.data || {};
        if (p.action === 'case' && p.data) play(p.data);
    });

    // Browser preview: open the page with ?case to watch a sample spin.
    if (!window.invokeNative && /[?&]case\b/.test(location.search)) {
        const pool = [
            { item: 'cash', label: 'Pocket money', rarity: 'common' },
            { item: 'jerry_can', label: 'Jerry Can', rarity: 'common' },
            { item: 'cash', label: 'Cash stack', rarity: 'uncommon' },
            { item: 'armour', label: 'Body Armour', rarity: 'rare' },
            { item: 'nitro', label: 'Nitrous Bottle', rarity: 'epic' },
            { item: 'cash', label: 'Jackpot', rarity: 'legendary' },
        ];
        const reel = Array.from({ length: 56 }, () => pool[Math.floor(Math.random() * pool.length)]);
        reel[47] = { item: 'cash', label: 'Jackpot', rarity: 'legendary', amountText: '$18,250' };
        setTimeout(() => play({ reel, win: 48, seconds: 5 }), 300);
    }
})();
