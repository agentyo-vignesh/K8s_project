# ALB Ingress + ServiceAccount

The cluster already exists. This sets up the AWS Load Balancer Controller,
puts an app behind an ALB, and then gives the app pod its own AWS access.

```
01-app.yaml                nginx deployment + service
02-ingress.yaml            the Ingress that becomes an ALB
03-iamserviceaccount.yaml  IAM role + ServiceAccount for the controller
04-s3-sa.yaml              IAM role + ServiceAccount for the app pod
05-app-s3.yaml             the app, reading its page from S3
```

---

## Setup

**1** — Set every value once; everything below reads these.
```bash
export CLUSTER=<your-cluster-name>
export REGION=ap-south-1
export ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
export VPC=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "$CLUSTER $REGION $ACCOUNT $VPC"
```

**2** — Point kubectl at the cluster and prove you can reach it.
```bash
aws eks update-kubeconfig --name $CLUSTER --region $REGION
kubectl get nodes
```

---

## Subnet tags

**3** — Find which subnets are public and which are private, from their routes: a `0.0.0.0/0` route to `igw-` means public, to `nat-` means private.
```bash
export PUB=$(aws ec2 describe-route-tables --region $REGION --filters Name=vpc-id,Values=$VPC --query 'RouteTables[?Routes[?starts_with(GatewayId || `x`, `igw-`)]].Associations[].SubnetId' --output text)
export PRIV=$(aws ec2 describe-route-tables --region $REGION --filters Name=vpc-id,Values=$VPC --query 'RouteTables[?Routes[?NatGatewayId!=null]].Associations[].SubnetId' --output text)
echo "$PUB"; echo "$PRIV"
```

**4** — Tag them; the controller finds subnets **by tag**, not by config, so without this the Ingress never gets an address.
```bash
aws ec2 create-tags --region $REGION --resources $PUB --tags Key=kubernetes.io/role/elb,Value=1 Key=kubernetes.io/cluster/$CLUSTER,Value=shared
aws ec2 create-tags --region $REGION --resources $PRIV --tags Key=kubernetes.io/role/internal-elb,Value=1 Key=kubernetes.io/cluster/$CLUSTER,Value=shared
```

---

## Controller

**5** — Download the permissions the controller needs and create them as an IAM policy; `EntityAlreadyExists` here is fine, it means the account already has it.
```bash
curl -sL -o alb-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy --policy-document file://alb-iam-policy.json
```

**6** — Register the cluster's OIDC issuer in IAM, which is what lets AWS trust a token the cluster signed.
```bash
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER --region $REGION --approve
```

**7** — Create the IAM role **and** the ServiceAccount that points at it; `eksctl` writes the trust policy, where the issuer has to appear in three places and one typo fails silently.
```bash
sed -e "s|<CLUSTER>|$CLUSTER|" -e "s|<REGION>|$REGION|" -e "s|<ACCOUNT>|$ACCOUNT|" 03-iamserviceaccount.yaml > isa.yaml
eksctl create iamserviceaccount -f isa.yaml --override-existing-serviceaccounts --approve
```

**8** — Confirm the ServiceAccount exists and carries the role ARN; if this is empty or missing, stop here — step 9 will report success and still create zero pods.
```bash
kubectl get sa aws-load-balancer-controller -n kube-system -o jsonpath='{.metadata.annotations}'
```

**9** — Install the controller, telling it not to create the ServiceAccount because step 7 already did.
```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system --set clusterName=$CLUSTER --set region=$REGION --set vpcId=$VPC --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller --wait
```

**10** — Check it is running and that it registered the `alb` IngressClass, which is what `ingressClassName: alb` resolves to.
```bash
kubectl get deploy -n kube-system aws-load-balancer-controller
kubectl get ingressclass
```

---

## App

**11** — Deploy nginx; note the pod IPs, they will show up as ALB targets shortly.
```bash
kubectl apply -f 01-app.yaml
kubectl get pods -n demo -o wide
```

**12** — Create the Ingress; the controller reads it and builds the ALB, which takes two to four minutes.
```bash
kubectl apply -f 02-ingress.yaml
kubectl get ingress -n demo -w
```

**13** — Wait until the load balancer is actually active, otherwise its DNS name does not exist yet and `curl` fails for a reason that has nothing to do with the cluster.
```bash
aws elbv2 wait load-balancer-available --region $REGION --load-balancer-arns $(aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text) && echo READY
```

**14** — Fetch the page through the ALB.
```bash
export H=$(kubectl get ingress web -n demo -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$H/
```

---

## What AWS actually built

**15** — Look at the ALB: it sits in the two public subnets, chosen purely from the tags in step 4.
```bash
export LB=$(aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 describe-load-balancers --region $REGION --query 'LoadBalancers[].{name:LoadBalancerName,scheme:Scheme,subnets:AvailabilityZones[].SubnetId,sg:SecurityGroups}' --output json
```

**16** — Look at the listener and its rules: your `path: /` became `/*`, and the listener's default action is a 404, so anything that matches no rule never reaches a pod.
```bash
export LS=$(aws elbv2 describe-listeners --region $REGION --load-balancer-arn $LB --query 'Listeners[0].ListenerArn' --output text)
aws elbv2 describe-listeners --region $REGION --load-balancer-arn $LB --query 'Listeners[].{port:Port,default:DefaultActions[0].Type}' --output json
aws elbv2 describe-rules --region $REGION --listener-arn $LS --query 'Rules[].{pri:Priority,path:Conditions[].Values,action:Actions[0].Type}' --output json
```

**17** — Compare the ALB's targets with the pods: the target addresses are **pod** IPs, not node IPs, because of `target-type: ip`.
```bash
export TG=$(aws elbv2 describe-target-groups --region $REGION --load-balancer-arn $LB --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 describe-target-health --region $REGION --target-group-arn $TG --query 'TargetHealthDescriptions[].{id:Target.Id,state:TargetHealth.State}' --output json
kubectl get pods -n demo -o wide
```

**18** — See the object that keeps those targets in sync; it watches the Service's endpoints and registers or removes targets as pods come and go.
```bash
kubectl get targetgroupbindings -n demo
```

**19** — See the rule the controller wrote into your cluster's security group so the ALB is allowed to reach the pods; nobody asked for this, and without it every target would stay unhealthy with no explanation.
```bash
export NODESG=$(aws eks describe-cluster --name $CLUSTER --region $REGION --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 describe-security-group-rules --region $REGION --filters Name=group-id,Values=$NODESG --query 'SecurityGroupRules[?!IsEgress].{port:FromPort,src:ReferencedGroupInfo.GroupId,desc:Description}' --output json
```

---

## Delete

**20** — Delete the Ingress first and wait for the ALB to go; the controller is the only thing that can remove it.
```bash
kubectl delete -f 02-ingress.yaml
aws elbv2 describe-load-balancers --region $REGION --query 'length(LoadBalancers)'
```

**21** — Only now remove the app, the controller and its IAM role.
```bash
kubectl delete -f 01-app.yaml
helm uninstall aws-load-balancer-controller -n kube-system
eksctl delete iamserviceaccount --cluster=$CLUSTER --region=$REGION --namespace=kube-system --name=aws-load-balancer-controller
```

> Order matters. The TargetGroupBinding carries a finalizer that only the
> controller clears. Remove the controller first and the namespace stays in
> `Terminating` forever and the ALB is orphaned.

---

## When something fails

| Symptom | Do this |
|---|---|
| Step 5 `EntityAlreadyExists` | Skip it, the policy is already there |
| Step 8 empty or `NotFound` | **A** below |
| Step 10 shows `0/2` | `kubectl describe deploy aws-load-balancer-controller -n kube-system` and read the `ReplicaFailure` line |
| Step 12 address stays empty | `kubectl describe ingress web -n demo`, then redo step 4 |
| Step 9 `has no deployed releases` | **B** below |
| `curl: (6) Could not resolve host` | `nslookup $H 8.8.8.8` — if Google cannot find it either, the ALB is still provisioning, so wait; if only you cannot, run `ipconfig /flushdns` |
| `Forbidden ... at the cluster scope` | **C** below |

**A** — Create the ServiceAccount by hand and restart the controller so the new pods pick it up.
```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system eks.amazonaws.com/role-arn=$(aws iam list-roles --query "Roles[?contains(RoleName,'addon-iamserviceaccount')].Arn | [0]" --output text)
kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system
```

**B** — A previous release is stuck in a non-deployed state; `helm list` hides it, `helm list -a` shows it, and deleting its Secret erases Helm's memory of it.
```bash
helm list -a -A
kubectl delete secret -n kube-system -l owner=helm,name=aws-load-balancer-controller
kubectl delete ingressclass alb --ignore-not-found
kubectl get crd -o name | grep elbv2 | xargs -r kubectl delete
```

**C** — Your IAM principal has namespace-scoped access only; cluster-scoped things like IngressClass, nodes and CRDs need a wider scope.
```bash
aws eks associate-access-policy --region $REGION --cluster-name $CLUSTER --principal-arn $(aws sts get-caller-identity --query Arn --output text) --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy --access-scope type=cluster
```

---

# Part 2 — giving the app pod its own AWS access

The ServiceAccount above belongs to the **controller**. This one belongs to
the **app**. Same mechanism, different pod, different permissions.

```
aws-load-balancer-controller   kube-system   elasticloadbalancing:*, ec2:*
web-sa                         demo          s3:GetObject, s3:ListBucket
```

**S1** — Create a bucket to read from.
```bash
export BUCKET=alb-demo-$ACCOUNT
aws s3 mb s3://$BUCKET --region $REGION
```

**S2** — Put the page the pod will fetch into it.
```bash
cat > index.html <<'EOF'
<!doctype html><title>from S3</title>
<body style="font-family:system-ui;padding:3rem"><h1>This page came from S3</h1></body>
EOF
aws s3 cp index.html s3://$BUCKET/index.html
```

**S3** — Allow exactly this bucket and nothing else; both statements are needed, because `ListBucket` applies to the bucket and `GetObject` to the objects inside it.
```bash
cat > s3-read.json <<EOF
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["s3:GetObject"],  "Resource": "arn:aws:s3:::$BUCKET/*" },
  { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::$BUCKET" } ] }
EOF
aws iam create-policy --policy-name web-s3-read --policy-document file://s3-read.json
```

**S4** — Create the role and the ServiceAccount for the app, in the `demo` namespace this time.
```bash
sed -e "s|<CLUSTER>|$CLUSTER|" -e "s|<REGION>|$REGION|" -e "s|<ACCOUNT>|$ACCOUNT|" 04-s3-sa.yaml > sa.yaml
eksctl create iamserviceaccount -f sa.yaml --override-existing-serviceaccounts --approve
```

**S5** — Confirm the annotation, same check as step 8.
```bash
kubectl get sa web-sa -n demo -o jsonpath='{.metadata.annotations}'
```

**S6** — Replace the app with a version whose init container copies the page out of S3 before nginx starts.
```bash
sed "s|<BUCKET>|$BUCKET|" 05-app-s3.yaml | kubectl apply -f -
kubectl get pods -n demo -w
```

**S7** — Read the init container's log: it prints the IAM role it became, then the download, and the browser now shows the S3 page.
```bash
kubectl logs -n demo deploy/web -c fetch
curl http://$H/
```

**S8** — Prove no credential was stored anywhere: there is no Secret, and the only AWS values in the pod are a role ARN and a path to a short-lived token the webhook injected.
```bash
kubectl get secrets -n demo --field-selector type=Opaque
kubectl exec -n demo deploy/web -c nginx -- env | grep AWS
```

**S9** — Break it: remove the annotation and restart, because the annotation is read once at pod creation and changing it does nothing to a running pod.
```bash
kubectl annotate sa web-sa -n demo eks.amazonaws.com/role-arn-
kubectl rollout restart deploy/web -n demo
kubectl logs -n demo deploy/web -c fetch
```

**S10** — Put it back.
```bash
kubectl annotate sa web-sa -n demo eks.amazonaws.com/role-arn=$(aws iam list-roles --query "Roles[?contains(RoleName,'demo-web-sa')].Arn | [0]" --output text)
kubectl rollout restart deploy/web -n demo
```

**S11** — Remove the role, the policy and the bucket.
```bash
eksctl delete iamserviceaccount --cluster=$CLUSTER --region=$REGION --namespace=demo --name=web-sa
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT:policy/web-s3-read
aws s3 rb s3://$BUCKET --force
```
