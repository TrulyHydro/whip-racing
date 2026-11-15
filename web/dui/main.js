(() => {
    'use strict';

    const distance = document.getElementById('distance');
    const label = document.getElementById('label');
    const body = document.body;

    // Messages arrive via SendDuiMessage from the client. Only the values that
    // actually changed are written -- this page is repainted into a texture, so
    // a needless DOM write is a needless texture upload.
    let lastDistance = null;
    let lastLabel = null;
    let lastState = null;

    window.addEventListener('message', (event) => {
        const data = event.data || {};

        if (data.distance !== undefined && data.distance !== lastDistance) {
            distance.textContent = data.distance;
            lastDistance = data.distance;
        }

        if (data.label !== undefined && data.label !== lastLabel) {
            label.textContent = data.label;
            lastLabel = data.label;
        }

        if (data.state !== undefined && data.state !== lastState) {
            body.className = data.state || '';
            lastState = data.state;
        }
    });
})();
