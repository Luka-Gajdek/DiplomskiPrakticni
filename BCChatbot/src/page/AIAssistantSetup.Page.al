page 50101 "AI Assistant Setup"
{
    Caption = 'AI Assistant Setup';
    PageType = Card;
    SourceTable = "AI Assistant Setup";
    UsageCategory = Administration;
    ApplicationArea = All;

    layout
    {
        area(Content)
        {
            group(General)
            {
                Caption = 'Connection';

                field("Backend URL"; Rec."Backend URL")
                {
                    ApplicationArea = All;
                    ToolTip = 'The ngrok (or local) URL of the FastAPI backend, e.g. https://xxxx.ngrok-free.app';
                }
                field("API Key"; Rec."API Key")
                {
                    ApplicationArea = All;
                    ExtendedDatatype = Masked;
                    ToolTip = 'The static API key configured in the FastAPI .env file.';
                }
            }
            group(HR)
            {
                Caption = 'HR Settings';

                field("Vacation Entitlement Days"; Rec."Vacation Entitlement Days")
                {
                    ApplicationArea = All;
                    ToolTip = 'Default number of vacation days per year per employee.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(TestConnection)
            {
                Caption = 'Test Connection';
                ApplicationArea = All;
                Image = TestReport;
                ToolTip = 'Send a health-check request to the FastAPI backend.';

                trigger OnAction()
                var
                    Mgt: Codeunit "AI Assistant Mgt.";
                begin
                    Mgt.TestConnection(Rec);
                end;
            }
        }
    }

    trigger OnOpenPage()
    var
        Setup: Record "AI Assistant Setup";
    begin
        if not Rec.Get('') then begin
            Rec.Init();
            Rec."Primary Key" := '';
            Rec."Vacation Entitlement Days" := 25;
            Rec.Insert();
        end;
    end;
}
