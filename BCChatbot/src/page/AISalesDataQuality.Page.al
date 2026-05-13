page 50106 "AI Sales Data Quality"
{
    Caption = 'Sales Prediction — Data Quality';
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
                Caption = 'Items are sorted by number of sales records (last 2 years). Sales prediction requires at least 3 records.';
            }
            repeater(Lines)
            {
                field("No."; Rec."No.")
                {
                    ApplicationArea = All;
                    Caption = 'Item No.';
                    ToolTip = 'Item number.';
                }
                field(Name; Rec.Name)
                {
                    ApplicationArea = All;
                    Caption = 'Description';
                    ToolTip = 'Item description.';
                }
                field("Record Count"; Rec."Record Count")
                {
                    ApplicationArea = All;
                    Caption = 'Sales Records (2y)';
                    ToolTip = 'Number of item ledger entries of type Sale in the last 2 years.';
                    Style = Favorable;
                    StyleExpr = Rec."Meets Threshold";
                }
                field("Meets Threshold"; Rec."Meets Threshold")
                {
                    ApplicationArea = All;
                    Caption = 'OK for Prediction';
                    ToolTip = 'True if this item has enough sales records to run the prediction model.';
                }
                field("Threshold"; Rec.Threshold)
                {
                    ApplicationArea = All;
                    Caption = 'Min. Required';
                    ToolTip = 'Minimum number of records required by the prediction model.';
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
                ToolTip = 'Reload data from item ledger entries.';

                trigger OnAction()
                begin
                    LoadData();
                    CurrPage.Update(false);
                end;
            }
            action(ShowOnlyOk)
            {
                Caption = 'Show Only Ready Items';
                ApplicationArea = All;
                Image = Filter;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Filter the list to show only items that meet the minimum threshold.';

                trigger OnAction()
                begin
                    Rec.SetRange("Meets Threshold", true);
                    CurrPage.Update(false);
                end;
            }
            action(ShowAll)
            {
                Caption = 'Show All Items';
                ApplicationArea = All;
                Image = ClearFilter;
                Promoted = true;
                PromotedCategory = Process;
                ToolTip = 'Remove the filter and show all items.';

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
        Item: Record Item;
        ILE: Record "Item Ledger Entry";
        MinRecords: Integer;
        CutoffDate: Date;
    begin
        MinRecords := 3;
        CutoffDate := CalcDate('<-2Y>', Today());

        Rec.Reset();
        Rec.DeleteAll();

        Item.Reset();
        Item.SetRange(Blocked, false);
        if Item.FindSet() then
            repeat
                ILE.Reset();
                ILE.SetRange("Item No.", Item."No.");
                ILE.SetRange("Entry Type", ILE."Entry Type"::Sale);
                ILE.SetFilter("Posting Date", '>=%1', CutoffDate);

                Rec.Init();
                Rec."No." := Item."No.";
                Rec.Name := CopyStr(Item.Description, 1, MaxStrLen(Rec.Name));
                Rec."Record Count" := ILE.Count();
                Rec.Threshold := MinRecords;
                Rec."Meets Threshold" := Rec."Record Count" >= MinRecords;
                Rec.Insert();
            until Item.Next() = 0;

        Rec.SetCurrentKey("Record Count");
        Rec.Ascending(false);
    end;
}
