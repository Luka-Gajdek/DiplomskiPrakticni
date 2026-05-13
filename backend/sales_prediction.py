import warnings
import pandas as pd
import numpy as np
from typing import List, Dict, Any
from datetime import timedelta
import xgboost as xgb

warnings.filterwarnings("ignore")

# lowered because the demo DB doesn't have many sales records
MIN_DATA_POINTS = 3
FORECAST_HORIZON = 30  # days

FEATURE_COLS = [
    "day_of_week", "month", "quarter", "day_of_year",
    "lag_1", "lag_7", "lag_14", "lag_30",
    "rolling_mean_7", "rolling_mean_14", "rolling_mean_30",
]

# Removing dates with 0 sales
def _prepare_dataframe(history: List[Dict]) -> pd.DataFrame:
    df = pd.DataFrame(history)
    df["date"] = pd.to_datetime(df["date"])
    df = df.groupby("date", as_index=False).agg({"quantity": "sum"})
    df = df.sort_values("date").reset_index(drop=True)

    date_range = pd.date_range(start=df["date"].min(), end=df["date"].max(), freq="D")
    df = df.set_index("date").reindex(date_range, fill_value=0).reset_index()
    df.columns = ["date", "quantity"]
    return df


def _add_features(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df["day_of_week"] = df["date"].dt.dayofweek
    df["month"] = df["date"].dt.month
    df["quarter"] = df["date"].dt.quarter
    df["day_of_year"] = df["date"].dt.dayofyear

    for lag in [1, 7, 14, 30]:
        df[f"lag_{lag}"] = df["quantity"].shift(lag).fillna(0)

    for window in [7, 14, 30]:
        df[f"rolling_mean_{window}"] = df["quantity"].shift(1).rolling(window, min_periods=1).mean().fillna(0)

    return df


def predict(item_no: str, history: List[Dict], days: int = FORECAST_HORIZON) -> Dict[str, Any]:
    if len(history) < MIN_DATA_POINTS:
        return {"error": f"Insufficient data: need at least {MIN_DATA_POINTS} sales records, got {len(history)}."}

    if days < 1:
        return {"error": "Forecast period must be at least 1 day."}

    df = _prepare_dataframe(history)
    df = _add_features(df)

    X_train = df[FEATURE_COLS].values
    y_train = df["quantity"].values

    model = xgb.XGBRegressor(
        n_estimators=200,
        max_depth=4,
        learning_rate=0.1,
        subsample=0.8,
        colsample_bytree=0.8,
        random_state=42,
        verbosity=0,
    )
    model.fit(X_train, y_train)

    # each predicted day feeds back as a lag feature for the next one
    recent_qty = df["quantity"].tolist()
    last_date = df["date"].max()

    forecast = []
    for i in range(1, days + 1):
        next_date = last_date + timedelta(days=i)

        lag_1  = recent_qty[-1]  if len(recent_qty) >= 1  else 0
        lag_7  = recent_qty[-7]  if len(recent_qty) >= 7  else 0
        lag_14 = recent_qty[-14] if len(recent_qty) >= 14 else 0
        lag_30 = recent_qty[-30] if len(recent_qty) >= 30 else 0

        rolling_7  = float(np.mean(recent_qty[-7:]))
        rolling_14 = float(np.mean(recent_qty[-14:]))
        rolling_30 = float(np.mean(recent_qty[-30:]))

        features = np.array([[
            next_date.dayofweek,
            next_date.month,
            next_date.quarter,
            next_date.dayofyear,
            lag_1, lag_7, lag_14, lag_30,
            rolling_7, rolling_14, rolling_30,
        ]])

        pred = max(0.0, float(model.predict(features)[0]))
        forecast.append(pred)
        recent_qty.append(pred)

    predicted_quantity = float(np.sum(forecast))

    start_date = last_date + timedelta(days=1)
    end_date = start_date + timedelta(days=days - 1)

    return {
        "item_no": item_no,
        "predicted_quantity": round(predicted_quantity, 2),
        "forecast_period": f"{start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}",
    }
