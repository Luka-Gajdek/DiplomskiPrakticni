controladdin "AI Chat Addin"
{
    RequestedHeight = 600;
    MinimumHeight = 400;
    VerticalShrink = true;
    VerticalStretch = true;
    HorizontalShrink = true;
    HorizontalStretch = true;

    StartupScript = 'src/controladdin/js/AIChatAddin.js';
    StyleSheets = 'src/controladdin/css/AIChatAddin.css';

    event ControlAddinReady();
    event MessageSent(userMessage: Text);

    procedure AddMessage(sender: Text; message: Text; isUser: Boolean);
    procedure SetTyping(isTyping: Boolean);
    procedure ClearMessages();
    procedure InitializeGreeting(greeting: Text);
}
