(function () {
    // ── Build the chat shell ──────────────────────────────────────────────────
    var container = document.getElementById('controlAddIn') || document.body;

    container.innerHTML = [
        '<div id="chatContainer">',
        '  <div id="chatHeader">',
        '    <div class="hdr-avatar">&#128025;</div>',
        '    <div class="hdr-info">',
        '      <div class="hdr-title">AI Assistant</div>',
        '      <div class="hdr-sub"><span class="status-dot"></span>Powered by llama3</div>',
        '    </div>',
        '  </div>',
        '  <div id="chatMessages"></div>',
        '  <div id="chatInputArea">',
        '    <textarea id="chatInput" placeholder="Type a message\u2026" rows="1"></textarea>',
        '    <button id="sendBtn" title="Send (Enter)">',
        '      <svg viewBox="0 0 24 24"><line x1="22" y1="2" x2="11" y2="13"/><polygon points="22 2 15 22 11 13 2 9 22 2"/></svg>',
        '    </button>',
        '  </div>',
        '</div>'
    ].join('');

    var messagesEl = document.getElementById('chatMessages');
    var inputEl = document.getElementById('chatInput');
    var sendBtn = document.getElementById('sendBtn');

    // ── Input handlers ────────────────────────────────────────────────────────
    inputEl.addEventListener('keydown', function (e) {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            doSend();
        }
    });

    inputEl.addEventListener('input', function () {
        this.style.height = 'auto';
        this.style.height = Math.min(this.scrollHeight, 150) + 'px';
    });

    sendBtn.addEventListener('click', doSend);

    // ── Core send ─────────────────────────────────────────────────────────────
    function doSend() {
        var msg = inputEl.value.trim();
        if (!msg) return;

        appendMessage('You', msg, true);
        showTyping();

        inputEl.value = '';
        inputEl.style.height = 'auto';
        inputEl.focus();

        Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('MessageSent', [msg]);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    function appendMessage(sender, text, isUser) {
        hideTyping();

        var wrapper = document.createElement('div');
        wrapper.className = 'msg-wrap ' + (isUser ? 'msg-user' : 'msg-bot');

        if (!isUser) {
            var av = document.createElement('div');
            av.className = 'msg-av';
            av.textContent = '\uD83D\uDC19';
            wrapper.appendChild(av);
        }

        var col = document.createElement('div');
        col.className = 'msg-col';

        var bubble = document.createElement('div');
        bubble.className = 'msg-bubble';
        bubble.innerHTML = formatText(text);

        var ts = document.createElement('div');
        ts.className = 'msg-ts';
        ts.textContent = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

        col.appendChild(bubble);
        col.appendChild(ts);
        wrapper.appendChild(col);
        messagesEl.appendChild(wrapper);
        scrollBottom();
    }

    function showTyping() {
        if (document.getElementById('typingDots')) return;
        var wrapper = document.createElement('div');
        wrapper.id = 'typingDots';
        wrapper.className = 'msg-wrap msg-bot';
        wrapper.innerHTML =
            '<div class="msg-av">\uD83D\uDC19</div>' +
            '<div class="msg-col"><div class="msg-bubble typing-bubble">' +
            '<span class="dot"></span><span class="dot"></span><span class="dot"></span>' +
            '</div></div>';
        messagesEl.appendChild(wrapper);
        scrollBottom();
    }

    function hideTyping() {
        var el = document.getElementById('typingDots');
        if (el) el.parentNode.removeChild(el);
    }

    function scrollBottom() {
        messagesEl.scrollTop = messagesEl.scrollHeight;
    }

    function formatText(raw) {
        // Split on [IMG:...] markers so image data is never HTML-escaped
        var parts = raw.split(/\[IMG:(data:[^\]]+)\]/);
        var result = '';
        for (var i = 0; i < parts.length; i++) {
            if (i % 2 === 0) {
                result += parts[i]
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;')
                    .replace(/\\n/g, '\n')
                    .replace(/\n/g, '<br>')
                    .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
            } else {
                result += '<img src="' + parts[i] + '" style="max-width:100%;border-radius:8px;margin-top:8px;">';
            }
        }
        return result;
    }

    // ── AL-callable procedures ────────────────────────────────────────────────
    window.AddMessage = function (sender, message, isUser) {
        appendMessage(sender, message, isUser);
    };

    window.SetTyping = function (isTyping) {
        if (isTyping) showTyping(); else hideTyping();
    };

    window.ClearMessages = function () {
        messagesEl.innerHTML = '';
    };

    window.InitializeGreeting = function (greeting) {
        appendMessage('AI Assistant', greeting, false);
    };

    // ── Signal AL the control is ready ────────────────────────────────────────
    Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('ControlAddinReady', []);
})();
