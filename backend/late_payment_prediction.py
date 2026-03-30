import warnings
import pandas as pd
import numpy as np
from typing import List, Dict, Any
from xgboost import XGBClassifier
from sklearn.preprocessing import LabelEncoder

warnings.filterwarnings("ignore")

MIN_TRAINING_RECORDS = 20


def predict(training_data: List[Dict], invoices_to_predict: List[Dict]) -> Dict[str, Any]:
    if len(training_data) < MIN_TRAINING_RECORDS:
        return {"error": f"Insufficient training data: need at least {MIN_TRAINING_RECORDS} closed invoices, got {len(training_data)}."}

    if not invoices_to_predict:
        return {"error": "No open invoices to predict."}

    df_train = pd.DataFrame(training_data)
    df_pred = pd.DataFrame(invoices_to_predict)

    # Per-customer historical aggregates used as features
    customer_stats = df_train.groupby("customer_no").agg(
        cust_late_rate=("was_late", "mean"),
        cust_avg_days_late=("days_late", "mean"),
        cust_invoice_count=("invoice_amount", "count"),
        cust_avg_amount=("invoice_amount", "mean"),
    ).reset_index()

    # Encode posting group consistently across train + predict
    le = LabelEncoder()
    le.fit(pd.concat([df_train["customer_posting_group"], df_pred["customer_posting_group"]]).unique())
    df_train["posting_group_enc"] = le.transform(df_train["customer_posting_group"])
    df_pred["posting_group_enc"] = le.transform(df_pred["customer_posting_group"])

    df_train = df_train.merge(customer_stats, on="customer_no", how="left")
    df_pred = df_pred.merge(customer_stats, on="customer_no", how="left")

    # New customers with no history fall back to global averages
    global_defaults = customer_stats[["cust_late_rate", "cust_avg_days_late", "cust_invoice_count", "cust_avg_amount"]].mean()
    df_pred = df_pred.fillna(global_defaults)
    df_train = df_train.fillna(0)

    # Relative invoice size vs customer's typical invoice
    df_train["amount_vs_avg"] = df_train["invoice_amount"] / (df_train["cust_avg_amount"] + 1)
    df_pred["amount_vs_avg"] = df_pred["invoice_amount"] / (df_pred["cust_avg_amount"] + 1)

    feature_cols = [
        "invoice_amount",
        "payment_terms_days",
        "posting_group_enc",
        "cust_late_rate",
        "cust_avg_days_late",
        "cust_invoice_count",
        "cust_avg_amount",
        "amount_vs_avg",
    ]

    X_train = df_train[feature_cols].values
    y_train = df_train["was_late"].astype(int).values

    model = XGBClassifier(
        n_estimators=200,
        max_depth=4,
        learning_rate=0.1,
        subsample=0.8,
        colsample_bytree=0.8,
        random_state=42,
        verbosity=0,
        eval_metric="logloss",
    )
    model.fit(X_train, y_train)

    X_pred = df_pred[feature_cols].values
    probabilities = model.predict_proba(X_pred)[:, 1]
    predictions = probabilities >= 0.5

    results = []
    for i, (_, row) in enumerate(df_pred.iterrows()):
        will_be_late = bool(predictions[i])
        prob = float(probabilities[i])
        days_until_due = int(row.get("days_until_due", 0))

        # If already overdue, always mark as late
        if days_until_due < 0:
            will_be_late = True
            prob = 1.0

        expected_days_late = int(round(row["cust_avg_days_late"])) if will_be_late else 0

        results.append({
            "document_no": str(row.get("document_no", "")),
            "customer_no": str(row["customer_no"]),
            "invoice_amount": round(float(row["invoice_amount"]), 2),
            "days_until_due": days_until_due,
            "will_be_late": will_be_late,
            "probability": round(prob, 2),
            "expected_days_late": expected_days_late,
        })

    return {"predictions": results}
