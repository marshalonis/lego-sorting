#!/usr/bin/env python3
import os
import aws_cdk as cdk
from stacks.lego_stack import LegoSortingStack

app = cdk.App()

LegoSortingStack(
    app,
    "LegoSortingStack",
    env=cdk.Environment(
        account=os.environ["CDK_DEFAULT_ACCOUNT"],
        region="us-east-1",
    ),
)

app.synth()
