page 50107 "AI Payment Data Quality"
{
    Caption = 'Late Payment Prediction — Data Quality';
    PageType = List;
    SourceTable = "AI Data Quality Buffer";
    SourceTableTemporary = true;
    Editable = false;
    UsageCategory = Tasks;
    ApplicationArea = All;

    layout
    {
        area(Content)
        {
            label(InfoLabel)
            {
                ApplicationArea = All;
                Caption = 'Customers are sorted by number of closed invoices (last 2 years). Late payment prediction uses all closed invoices as training data and requires at least 5 total.';
            }
            repeater(Lines)
            {
                field("No."; Rec."No.")
                {
                    ApplicationArea = All;
                    Caption = 'Customer No.';
                    ToolTip = 'Customer number.';
                }
                field(Name; Rec.Name)
                {
                    ApplicationArea = All;
                    Caption = 'Customer Name';
                    ToolTip = 'Customer name.';
                }
                field("Record Count"; Rec."Record Count")
                {
                    ApplicationArea = All;
                    Caption = 'Closed Invoices (2y)';
                    ToolTip = 'Number of closed (paid) invoices in the last 2 years used to train the model.';
                    Style = Favorable;
                    StyleExpr = Rec."Meets Threshold";
                }
                field(HasOpenInvoices; HasOpenInvoicesForCustomer(Rec."No."))
                {
                    ApplicationArea = All;
                    Caption = 'Has Open Invoices';
                    ToolTip = 'Whether this customer currently has open invoices to predict.';
                }
                field("Meets Threshold"; Rec."Meets Threshold")
                {
                    ApplicationArea = All;
                    Caption = 'History OK';
                    ToolTip = 'True if this customer has enough closed invoices to be well represented in the model.';
                }
                field("Threshold"; Rec.Threshold)
                {
                    ApplicationArea = All;
                    Caption = 'Min. Required';
                    ToolTip = 'Minimum number of closed invoices for the model to be meaningful.';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(Refresh)
            {
                Caption = 'Refresh';
                ApplicationArea = All;
                Image = Refresh;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Reload data from customer ledger entries.';

                trigger OnAction()
                begin
                    LoadData();
                    CurrPage.Update(false);
                end;
            }
            action(ShowReadyWithOpen)
            {
                Caption = 'Show Ready + Open Invoices';
                ApplicationArea = All;
                Image = Filter;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Filter to customers that have enough history AND currently have open invoices — best candidates for demo.';

                trigger OnAction()
                begin
                    Rec.SetRange("Meets Threshold", true);
                    CurrPage.Update(false);
                end;
            }
            action(ShowAll)
            {
                Caption = 'Show All Customers';
                ApplicationArea = All;
                Image = ClearFilter;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Remove filters and show all customers.';

                trigger OnAction()
                begin
                    Rec.SetRange("Meets Threshold");
                    CurrPage.Update(false);
                end;
            }
        }
    }

    trigger OnOpenPage()
    begin
        LoadData();
    end;

    local procedure LoadData()
    var
        Customer: Record Customer;
        CLE: Record "Cust. Ledger Entry";
        MinPerCustomer: Integer;
        CutoffDate: Date;
    begin
        // The model needs 5 total closed invoices across ALL customers.
        // We show per-customer counts so you know who contributes most to training
        // and which customers have enough personal history for meaningful individual prediction.
        MinPerCustomer := 3;
        CutoffDate := CalcDate('<-2Y>', Today());

        Rec.Reset();
        Rec.DeleteAll();

        Customer.Reset();
        if Customer.FindSet() then
            repeat
                CLE.Reset();
                CLE.SetRange("Customer No.", Customer."No.");
                CLE.SetRange("Document Type", CLE."Document Type"::Invoice);
                CLE.SetRange(Open, false);
                CLE.SetFilter("Closed at Date", '<>%1', 0D);
                CLE.SetFilter("Posting Date", '>=%1', CutoffDate);

                Rec.Init();
                Rec."No." := Customer."No.";
                Rec.Name := CopyStr(Customer.Name, 1, MaxStrLen(Rec.Name));
                Rec."Record Count" := CLE.Count();
                Rec.Threshold := MinPerCustomer;
                Rec."Meets Threshold" := Rec."Record Count" >= MinPerCustomer;
                Rec.Insert();
            until Customer.Next() = 0;

        Rec.SetCurrentKey("Record Count");
        Rec.Ascending(false);
    end;

    local procedure HasOpenInvoicesForCustomer(CustomerNo: Code[20]): Boolean
    var
        CLE: Record "Cust. Ledger Entry";
    begin
        CLE.SetRange("Customer No.", CustomerNo);
        CLE.SetRange("Document Type", CLE."Document Type"::Invoice);
        CLE.SetRange(Open, true);
        exit(not CLE.IsEmpty());
    end;
}
