#!/usr/bin/env python3
import aws_cdk as cdk
from stacks.lego_stack import LegoSortingStack

app = cdk.App()

LegoSortingStack(
    app,
    "LegoSortingStack",
    env=cdk.Environment(
        account=app.node.try_get_context("account"),
        region=app.node.try_get_context("region") or "us-east-1",
    ),
)

app.synth()
