page 50105 "AI Assistant Chat UI"
{
    Caption = 'AI Assistant';
    PageType = Card;
    UsageCategory = Tasks;
    ApplicationArea = All;

    layout
    {
        area(Content)
        {
            usercontrol(ChatAddin; "AI Chat Addin")
            {
                ApplicationArea = All;

                trigger ControlAddinReady()
                begin
                    CurrPage.ChatAddin.InitializeGreeting(
                        'Hello! I am your Business Central AI assistant powered by llama3.\n\nYou can ask me about:\n' +
                        '  **Vacation days** – e.g. "Vacation for Terry"\n' +
                        '  **Sales forecast** – e.g. "Predict sales for item 1900-S"\n' +
                        '  **Item inventory** – e.g. "Show me info about Tokyo chair"\n' +
                        '  **Item pictures** – e.g. "Show me a picture of the Amsterdam lamp"\n' +
                        '  **Prediction for paying open invoices** – e.g. "will invoice 103183 be payed off in time?"\n' +
                        '  **General BC questions** – just ask!'
                    );
                end;

                trigger MessageSent(userMessage: Text)
                var
                    Mgt: Codeunit "AI Assistant Mgt.";
                    Reply: Text;
                    TrimmedMsg: Text;
                begin
                    TrimmedMsg := userMessage.Trim();
                    if TrimmedMsg = '' then
                        exit;

                    //fetch the reply.
                    Reply := Mgt.SendMessage(TrimmedMsg, ChatHistory);
                    CurrPage.ChatAddin.AddMessage('AI Assistant', Reply, false);
                end;
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(ClearChat)
            {
                Caption = 'Clear Chat';
                ApplicationArea = All;
                Image = Delete;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Clear all messages and start a new conversation.';

                trigger OnAction()
                begin
                    Clear(ChatHistory);
                    CurrPage.ChatAddin.ClearMessages();
                    CurrPage.ChatAddin.InitializeGreeting('Chat cleared. How can I help you?');
                end;
            }
            action(SalesDataQuality)
            {
                Caption = 'Sales Prediction — Data Quality';
                ApplicationArea = All;
                Image = ItemStatistics;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Show which items have enough sales records to use with the sales prediction feature.';

                trigger OnAction()
                begin
                    Page.Run(Page::"AI Sales Data Quality");
                end;
            }
            action(PaymentDataQuality)
            {
                Caption = 'Late Payment — Data Quality';
                ApplicationArea = All;
                Image = CustomerLedger;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Show which customers have enough invoice history to use with the late payment prediction feature.';

                trigger OnAction()
                begin
                    Page.Run(Page::"AI Payment Data Quality");
                end;
            }
        }
    }

    var
        ChatHistory: JsonArray;
}
