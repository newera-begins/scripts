- Use this script when the loop is active. Save it on the admin workstation as capture-br-ex-churn.sh, make it executable, and run it with the affected node name:

```
chmod +x capture-br-ex-churn.sh
./capture-br-ex-churn.sh master2
```

- The second argument is optional and is the duration in seconds. For example, the following records two minutes instead of the default one minute:

```
./capture-br-ex-churn.sh master2 120

```
